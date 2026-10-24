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
                self.assertEqual(allowed(app, "acm:DeleteCertificate", f"arn:aws:acm:{REGION}:{ACCOUNT}:certificate/123", context), expected)

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
            cert = f"arn:aws:acm:{REGION}:{ACCOUNT}:certificate/new"
            self.assertTrue(allowed(app, "acm:AddTagsToCertificate", cert, request))
            request["aws:RequestedRegion"] = REGION
            self.assertTrue(allowed(app, "acm:RequestCertificate", "*", request))

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


if __name__ == "__main__":
    unittest.main()
