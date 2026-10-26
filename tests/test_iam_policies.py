"""Evaluate the real HCL policy expressions offline; no AWS credentials or provider.

This checks policy intent for representative requests, not AWS's IAM simulator,
SCPs, permissions boundaries, or the provider's full runtime API call sequence.
"""
import fnmatch
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ACCOUNT = "123456789012"
REGION = "us-east-1"
PREFIX = f"arn:aws:ec2:{REGION}:{ACCOUNT}:"


def expression(text, assignment="policy"):
    match = re.search(r"\b" + assignment + r"\s*=\s*(jsonencode\(\{.*?\n  \}\))", text, re.S)
    if not match:
        raise AssertionError("Policy expression not found: " + assignment)
    return match[1]


def as_list(value):
    return value if isinstance(value, list) else [value]


def allowed(policy, action, resource, context=None):
    """Small evaluator for only the operators present in these generated policies."""
    context = context or {}
    found = False
    for statement in policy["Statement"]:
        if not any(fnmatch.fnmatchcase(action.lower(), a.lower()) for a in as_list(statement["Action"])):
            continue
        if not any(fnmatch.fnmatchcase(resource, r) for r in as_list(statement["Resource"])):
            continue
        matches = True
        for operator, conditions in statement.get("Condition", {}).items():
            for key, expected in conditions.items():
                values = as_list(expected)
                actual = context.get(key)
                if operator == "StringEquals":
                    ok = actual is not None and actual in values
                elif operator in ["StringLike", "ArnLike"]:
                    ok = actual is not None and any(fnmatch.fnmatchcase(actual, v) for v in values)
                elif operator == "Null":
                    ok = (actual is None) == (str(expected).lower() == "true")
                elif operator == "ForAllValues:StringNotEquals":
                    ok = all(v not in values for v in as_list(actual if actual is not None else []))
                else:
                    raise AssertionError("Unsupported condition operator " + operator)
                matches = matches and ok
        if matches:
            if statement["Effect"] == "Deny":
                return False
            found = True
    return found


class IAMPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        main = (ROOT / "modules/github-oidc/main.tf").read_text()
        app = main.split('resource "aws_iam_role_policy" "application"', 1)[1]
        monitoring = (ROOT / "modules/api-proxy/main.tf").read_text().split('resource "aws_sns_topic_policy" "alerts"', 1)[1]
        cls.policies = {}
        for environment in ["uat", "production"]:
            values = {
                "trust": expression(main, "assume_role_policy"),
                "state": expression(main),
                "application": expression(app),
                "notifications": expression(monitoring),
            }
            replacements = {
                "each.key": json.dumps(environment),
                "var.aws_account_id": json.dumps(ACCOUNT),
                "var.aws_region": json.dumps(REGION),
                "var.repository": json.dumps("test-owner/test-repo"),
                "var.state_bucket_arn": json.dumps("arn:aws:s3:::test-state"),
                "local.provider_arn": json.dumps(f"arn:aws:iam::{ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"),
                "aws_sns_topic.alerts.arn": json.dumps(f"arn:aws:sns:{REGION}:{ACCOUNT}:cc-{environment}-api-proxy-alerts"),
                "local.name": json.dumps(f"cc-{environment}-api-proxy"),
            }
            evaluated = []
            for key, value in values.items():
                for source, replacement in replacements.items():
                    value = value.replace(source, replacement)
                value = value.replace(f'local.log_bucket_arns["{environment}"]', json.dumps(f"arn:aws:s3:::cc-{ACCOUNT}-{REGION}-{environment}-api-proxy-logs"))
                evaluated.append(f"{key} = jsondecode({value})")
            with tempfile.TemporaryDirectory(prefix="cc-iam-test-") as directory:
                Path(directory, "main.tf").write_text("locals { policies = {\n" + "\n".join(evaluated) + "\n} }\n")
                result = subprocess.run(["terraform", "console", "-no-color"], cwd=directory, input="jsonencode(local.policies)\n", text=True, capture_output=True)
                if result.returncode:
                    raise AssertionError(result.stderr)
                cls.policies[environment] = json.loads(json.loads(result.stdout))

    def test_oidc_subject_is_exact_repository_and_environment(self):
        for environment, policies in self.policies.items():
            trust = policies["trust"]["Statement"][0]
            self.assertEqual(trust["Action"], "sts:AssumeRoleWithWebIdentity")
            self.assertEqual(trust["Condition"]["StringEquals"], {
                "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
                "token.actions.githubusercontent.com:sub": f"repo:test-owner/test-repo:environment:{environment}",
            })
            self.assertNotIn("*", trust["Principal"]["Federated"])

    def test_state_isolation_and_lock_cleanup(self):
        for environment, policies in self.policies.items():
            for candidate in ["uat", "production", "networking", "bootstrap"]:
                state = f"arn:aws:s3:::test-state/{candidate}/terraform.tfstate"
                self.assertEqual(allowed(policies["state"], "s3:PutObject", state), environment == candidate)
                self.assertFalse(allowed(policies["state"], "s3:DeleteObject", state))
                self.assertEqual(allowed(policies["state"], "s3:DeleteObject", state + ".tflock"), environment == candidate)
            self.assertFalse(allowed(policies["application"], "s3:DeleteBucket", "arn:aws:s3:::test-state"))

    def test_environment_resources_cannot_be_mutated_across_environments(self):
        for environment, policies in self.policies.items():
            app = policies["application"]
            for candidate in ["uat", "production"]:
                expected = environment == candidate
                cases = [
                    ("elasticloadbalancing:DeleteLoadBalancer", f"arn:aws:elasticloadbalancing:{REGION}:{ACCOUNT}:loadbalancer/app/cc-{candidate}-api-proxy/123"),
                    ("elasticloadbalancing:CreateListener", f"arn:aws:elasticloadbalancing:{REGION}:{ACCOUNT}:loadbalancer/app/cc-{candidate}-api-proxy/123"),
                    ("elasticloadbalancing:CreateRule", f"arn:aws:elasticloadbalancing:{REGION}:{ACCOUNT}:listener/app/cc-{candidate}-api-proxy/123/456"),
                    ("s3:PutBucketPolicy", f"arn:aws:s3:::cc-{ACCOUNT}-{REGION}-{candidate}-api-proxy-logs"),
                    ("cloudwatch:PutMetricAlarm", f"arn:aws:cloudwatch:{REGION}:{ACCOUNT}:alarm:cc-{candidate}-api-proxy-healthy-targets"),
                    ("sns:GetSubscriptionAttributes", f"arn:aws:sns:{REGION}:{ACCOUNT}:cc-{candidate}-api-proxy-alerts"),
                ]
                for action, resource in cases:
                    self.assertEqual(allowed(app, action, resource), expected, (environment, action, resource))
                context = {"aws:ResourceTag/Environment": candidate, "aws:ResourceTag/Stack": candidate}
                for action in ["ec2:DeleteSecurityGroup", "ec2:AuthorizeSecurityGroupEgress", "ec2:RevokeSecurityGroupIngress", "ec2:ModifySecurityGroupRules"]:
                    self.assertEqual(allowed(app, action, PREFIX + "security-group/sg-123", context), expected, (environment, action, candidate))

    def test_tagged_creation_allowed_but_existing_groups_cannot_be_taken_over(self):
        for environment, policies in self.policies.items():
            app = policies["application"]
            request = {"aws:RequestTag/Environment": environment, "aws:RequestTag/Stack": environment}
            self.assertTrue(allowed(app, "ec2:CreateSecurityGroup", PREFIX + "security-group/sg-new", request))
            self.assertTrue(allowed(app, "ec2:CreateSecurityGroup", PREFIX + "vpc/vpc-shared", {"aws:ResourceTag/Stack": "networking", "aws:ResourceTag/Project": "commerce-casino"}))
            self.assertFalse(allowed(app, "ec2:CreateSecurityGroup", PREFIX + "vpc/vpc-other"))
            self.assertTrue(allowed(app, "ec2:CreateTags", PREFIX + "security-group/sg-new", dict(request, **{"ec2:CreateAction": "CreateSecurityGroup"})))
            other = "production" if environment == "uat" else "uat"
            takeover = dict(request, **{"aws:ResourceTag/Environment": other, "aws:ResourceTag/Stack": other, "aws:TagKeys": ["Environment", "Stack"]})
            self.assertFalse(allowed(app, "ec2:CreateTags", PREFIX + "security-group/sg-other", takeover))
            own = {"aws:ResourceTag/Environment": environment, "aws:ResourceTag/Stack": environment, "aws:TagKeys": ["Name"]}
            self.assertTrue(allowed(app, "ec2:CreateTags", PREFIX + "security-group/sg-own", own))
            own["aws:TagKeys"] = ["Environment"]
            self.assertFalse(allowed(app, "ec2:DeleteTags", PREFIX + "security-group/sg-own", own))
            # No custom domain: the application role no longer manages ACM certificates.
            self.assertFalse(allowed(app, "acm:RequestCertificate", "*", dict(request, **{"aws:RequestedRegion": REGION})))
            distribution = f"arn:aws:cloudfront::{ACCOUNT}:distribution/E123"
            self.assertTrue(allowed(app, "cloudfront:CreateDistribution", distribution))
            self.assertTrue(allowed(app, "iam:CreateServiceLinkedRole", f"arn:aws:iam::{ACCOUNT}:role/aws-service-role/vpcorigin.cloudfront.amazonaws.com/AWSServiceRoleForCloudFrontVPCOrigin", {"iam:AWSServiceName": "vpcorigin.cloudfront.amazonaws.com"}))

    def test_cloudwatch_publish_is_scoped_to_own_account_and_alarm_prefix(self):
        for environment, policies in self.policies.items():
            statement = policies["notifications"]["Statement"][0]
            self.assertEqual(statement["Principal"], {"Service": "cloudwatch.amazonaws.com"})
            topic = statement["Resource"]
            context = {"aws:SourceAccount": ACCOUNT, "aws:SourceArn": f"arn:aws:cloudwatch:{REGION}:{ACCOUNT}:alarm:cc-{environment}-api-proxy-alb-5xx"}
            self.assertTrue(allowed(policies["notifications"], "sns:Publish", topic, context))
            context["aws:SourceAccount"] = "999999999999"
            self.assertFalse(allowed(policies["notifications"], "sns:Publish", topic, context))
            context["aws:SourceAccount"] = ACCOUNT
            context["aws:SourceArn"] = f"arn:aws:cloudwatch:{REGION}:{ACCOUNT}:alarm:unrelated-alarm"
            self.assertFalse(allowed(policies["notifications"], "sns:Publish", topic, context))

    def test_inline_policy_aggregate_stays_under_role_limit(self):
        for policies in self.policies.values():
            size = sum(len(json.dumps(policies[key], separators=(",", ":"))) for key in ["state", "application"])
            self.assertLess(size, 10240, f"Inline role policies exceed IAM quota: {size}")



def evaluate(expressions, replacements):
    """Render HCL policy expressions to JSON with terraform console (no provider needed)."""
    rendered = []
    for key, value in expressions.items():
        for source, replacement in replacements.items():
            value = value.replace(source, replacement)
        rendered.append(f"{key} = jsondecode({value})")
    with tempfile.TemporaryDirectory(prefix="cc-iam-test-") as directory:
        Path(directory, "main.tf").write_text("locals { policies = {\n" + "\n".join(rendered) + "\n} }\n")
        result = subprocess.run(["terraform", "console", "-no-color"], cwd=directory, input="jsonencode(local.policies)\n", text=True, capture_output=True)
        if result.returncode:
            raise AssertionError(result.stderr)
        return json.loads(json.loads(result.stdout))


def section(text, resource):
    return text.split(resource, 1)[1]


class MCPPolicyTests(unittest.TestCase):
    """Terraform roles gain MCP scope per environment; application CI roles stay narrow."""

    @classmethod
    def setUpClass(cls):
        main = (ROOT / "modules/github-oidc/main.tf").read_text()
        cls.policies = {}
        for environment in ["uat", "production"]:
            cls.policies[environment] = evaluate({
                "compute": expression(section(main, 'resource "aws_iam_policy" "mcp_compute"')),
                "operations": expression(section(main, 'resource "aws_iam_policy" "mcp_operations"')),
                "deploy": expression(section(main, 'resource "aws_iam_role_policy" "mcp_deploy"')),
                "push": expression(section(main, 'resource "aws_iam_role_policy" "mcp_image_push"')),
                "app_trust": expression(section(main, 'resource "aws_iam_role" "mcp_app"'), "assume_role_policy"),
                "networking": expression(section(main, 'resource "aws_iam_role_policy" "networking_shared_services"')),
            }, {
                "each.key": json.dumps(environment),
                "each.value": json.dumps(f"repo:test-owner/cc-mcp-server:environment:{environment}"),
                "var.aws_account_id": json.dumps(ACCOUNT),
                "var.aws_region": json.dumps(REGION),
                "var.mcp_ecr_repository_name": json.dumps("cc-mcp-server"),
                "local.provider_arn": json.dumps(f"arn:aws:iam::{ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"),
            })

    def test_terraform_role_cannot_touch_other_environment_mcp(self):
        for environment, policies in self.policies.items():
            for candidate in ["uat", "production"]:
                expected = environment == candidate
                compute = [
                    ("ecs:UpdateService", f"arn:aws:ecs:{REGION}:{ACCOUNT}:service/cc-{candidate}-mcp/cc-{candidate}-mcp"),
                    ("ecs:DeleteCluster", f"arn:aws:ecs:{REGION}:{ACCOUNT}:cluster/cc-{candidate}-mcp"),
                    ("elasticloadbalancing:DeleteLoadBalancer", f"arn:aws:elasticloadbalancing:{REGION}:{ACCOUNT}:loadbalancer/app/cc-{candidate}-mcp/123"),
                    ("iam:PutRolePolicy", f"arn:aws:iam::{ACCOUNT}:role/cc-{candidate}-mcp-execution"),
                ]
                operations = [
                    ("secretsmanager:DeleteSecret", f"arn:aws:secretsmanager:{REGION}:{ACCOUNT}:secret:cc-mcp/{candidate}/squirrel-AbCdEf"),
                    ("ssm:PutParameter", f"arn:aws:ssm:{REGION}:{ACCOUNT}:parameter/cc/{candidate}/mcp/image"),
                    ("logs:DeleteLogGroup", f"arn:aws:logs:{REGION}:{ACCOUNT}:log-group:/ecs/mcp-server/{candidate}"),
                    ("s3:PutBucketPolicy", f"arn:aws:s3:::cc-{ACCOUNT}-{REGION}-{candidate}-mcp-logs"),
                    ("cloudwatch:PutMetricAlarm", f"arn:aws:cloudwatch:{REGION}:{ACCOUNT}:alarm:cc-{candidate}-mcp-target-5xx"),
                ]
                for action, resource in compute:
                    self.assertEqual(allowed(policies["compute"], action, resource), expected, (environment, action))
                for action, resource in operations:
                    self.assertEqual(allowed(policies["operations"], action, resource), expected, (environment, action))
            # MCP permissions never reach the API Proxy or networking resources.
            self.assertFalse(allowed(policies["compute"], "elasticloadbalancing:DeleteLoadBalancer", f"arn:aws:elasticloadbalancing:{REGION}:{ACCOUNT}:loadbalancer/app/cc-{environment}-api-proxy/123"))
            self.assertFalse(allowed(policies["operations"], "ssm:PutParameter", f"arn:aws:ssm:{REGION}:{ACCOUNT}:parameter/cc/networking/contract"))

    def test_terraform_never_reads_secret_values_and_passes_roles_only_to_ecs_tasks(self):
        for environment, policies in self.policies.items():
            secret = f"arn:aws:secretsmanager:{REGION}:{ACCOUNT}:secret:cc-mcp/{environment}/squirrel-AbCdEf"
            for key in ["compute", "operations"]:
                self.assertFalse(allowed(policies[key], "secretsmanager:GetSecretValue", secret))
            role = f"arn:aws:iam::{ACCOUNT}:role/cc-{environment}-mcp-task"
            self.assertTrue(allowed(policies["compute"], "iam:PassRole", role, {"iam:PassedToService": "ecs-tasks.amazonaws.com"}))
            self.assertFalse(allowed(policies["compute"], "iam:PassRole", role, {"iam:PassedToService": "lambda.amazonaws.com"}))
            self.assertFalse(allowed(policies["compute"], "iam:PassRole", f"arn:aws:iam::{ACCOUNT}:role/cc-terraform-{environment}", {"iam:PassedToService": "ecs-tasks.amazonaws.com"}))

    def test_managed_policies_fit_iam_size_limit(self):
        for policies in self.policies.values():
            for key in ["compute", "operations"]:
                size = len(json.dumps(policies[key], separators=(",", ":")))
                self.assertLess(size, 6144, f"{key} managed policy exceeds IAM quota: {size}")

    def test_application_ci_roles_are_environment_scoped(self):
        for environment, policies in self.policies.items():
            trust = policies["app_trust"]["Statement"][0]["Condition"]["StringEquals"]
            self.assertEqual(trust["token.actions.githubusercontent.com:sub"], f"repo:test-owner/cc-mcp-server:environment:{environment}")
            deploy = policies["deploy"]
            for candidate in ["uat", "production"]:
                expected = environment == candidate
                self.assertEqual(allowed(deploy, "ecs:UpdateService", f"arn:aws:ecs:{REGION}:{ACCOUNT}:service/cc-{candidate}-mcp/cc-{candidate}-mcp"), expected)
                self.assertEqual(allowed(deploy, "ssm:PutParameter", f"arn:aws:ssm:{REGION}:{ACCOUNT}:parameter/cc/{candidate}/mcp/image"), expected)
                context = {"iam:PassedToService": "ecs-tasks.amazonaws.com"}
                self.assertEqual(allowed(deploy, "iam:PassRole", f"arn:aws:iam::{ACCOUNT}:role/cc-{candidate}-mcp-execution", context), expected)
            self.assertFalse(allowed(deploy, "iam:PassRole", f"arn:aws:iam::{ACCOUNT}:role/cc-terraform-{environment}", {"iam:PassedToService": "ecs-tasks.amazonaws.com"}))
            self.assertFalse(allowed(deploy, "ecs:DeleteService", f"arn:aws:ecs:{REGION}:{ACCOUNT}:service/cc-{environment}-mcp/cc-{environment}-mcp"))
            self.assertFalse(allowed(deploy, "ecr:PutImage", f"arn:aws:ecr:{REGION}:{ACCOUNT}:repository/cc-mcp-server"))
            push = policies["push"]
            self.assertTrue(allowed(push, "ecr:PutImage", f"arn:aws:ecr:{REGION}:{ACCOUNT}:repository/cc-mcp-server"))
            self.assertFalse(allowed(push, "ecr:PutImage", f"arn:aws:ecr:{REGION}:{ACCOUNT}:repository/other"))
            self.assertFalse(allowed(push, "ecs:UpdateService", f"arn:aws:ecs:{REGION}:{ACCOUNT}:service/cc-{environment}-mcp/cc-{environment}-mcp"))

    def test_networking_mutates_only_its_own_security_groups(self):
        networking = self.policies["uat"]["networking"]
        group = PREFIX + "security-group/sg-123"
        self.assertTrue(allowed(networking, "ec2:RevokeSecurityGroupEgress", group, {"aws:ResourceTag/Stack": "networking"}))
        for stack in ["uat", "production"]:
            self.assertFalse(allowed(networking, "ec2:DeleteSecurityGroup", group, {"aws:ResourceTag/Stack": stack}))
        self.assertTrue(allowed(networking, "ecr:CreateRepository", f"arn:aws:ecr:{REGION}:{ACCOUNT}:repository/cc-mcp-server"))
        self.assertFalse(allowed(networking, "ecr:CreateRepository", f"arn:aws:ecr:{REGION}:{ACCOUNT}:repository/other-team"))

if __name__ == "__main__":
    unittest.main()
