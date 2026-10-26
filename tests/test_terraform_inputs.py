"""Exercise actual variable validations and output persistence without an AWS provider."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class TerraformInputTests(unittest.TestCase):
    def run_variables(self, relative, variables):
        with tempfile.TemporaryDirectory(prefix="cc-input-test-") as directory:
            shutil.copyfile(ROOT / relative, Path(directory, "variables.tf"))
            Path(directory, "terraform.tfvars.json").write_text(json.dumps(variables))
            return subprocess.run(["terraform", "plan", "-input=false", "-no-color"], cwd=directory, capture_output=True, text=True)

    def test_public_subnets_require_distinct_azs_and_alb_capacity(self):
        private = {"a": {"cidr": "10.0.10.0/24", "availability_zone": "us-east-1a"}}
        valid = {
            "uat-a": {"cidr": "10.0.100.0/24", "availability_zone": "us-east-1a", "environment": "uat"},
            "uat-b": {"cidr": "10.0.101.0/24", "availability_zone": "us-east-1b", "environment": "uat"},
        }
        cases = [({}, True), (valid, True), (dict(valid, **{"uat-c": {"cidr": "10.0.102.0/24", "availability_zone": "us-east-1b", "environment": "uat"}}), False), ({k: dict(v, cidr=v["cidr"].replace("/24", "/28")) for k, v in valid.items()}, False)]
        for subnets, accepted in cases:
            result = self.run_variables("modules/network/variables.tf", {"vpc_cidr": "10.0.0.0/16", "private_subnets": private, "public_subnets": subnets})
            self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)

    def test_backend_targets_are_private_ipv4_not_public_vpn_endpoints(self):
        base = dict(environment="uat", aws_account_id="123456789012", aws_region="us-east-1", vpc_id="vpc-test", alb_subnet_ids=["subnet-a", "subnet-b"])
        for ip, accepted in [("172.19.16.23", True), ("10.0.1.20", True), ("192.168.1.20", True), ("66.215.9.236", False), ("172.32.1.1", False)]:
            result = self.run_variables("modules/api-proxy/variables.tf", dict(base, backend_targets={"first": ip}))
            self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)

    def test_enabled_application_requires_targets_recipients_and_valid_thresholds(self):
        base = dict(aws_account_id="123456789012")
        enabled = dict(base, enable_alb=True, backend_targets={"first": "172.19.16.23"}, alert_emails=["ops@example.com"])
        cases = [(base, True), (dict(base, enable_alb=True), False), (enabled, True), (dict(enabled, latency_p95_seconds=0), False), (dict(enabled, error_count_threshold=1.5), False), (dict(enabled, health_check_path="health"), False), (dict(enabled, additional_alarm_action_arns=["not-an-arn"]), False)]
        for environment in ["uat", "production"]:
            for values, accepted in cases:
                result = self.run_variables(f"live/{environment}/variables.tf", values)
                self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)

    def test_disabled_api_proxy_keeps_output_readable(self):
        for environment in ["uat", "production"]:
            source = (ROOT / f"live/{environment}/outputs.tf").read_text()
            output = 'output "api_proxy"' + source.split('output "api_proxy"', 1)[1]
            output = output.replace("module.api_proxy", "var.module_outputs")
            for enabled in [False, True]:
                with tempfile.TemporaryDirectory(prefix="cc-output-test-") as directory:
                    Path(directory, "main.tf").write_text('variable "enable_alb" { type = bool }\nvariable "module_outputs" { type = list(map(string)) }\n' + output)
                    expected = {"alb_dns_name": "example-alb.elb.amazonaws.com"} if enabled else {}
                    values = {"enable_alb": enabled, "module_outputs": [expected] if enabled else []}
                    Path(directory, "terraform.tfvars.json").write_text(json.dumps(values))
                    apply = subprocess.run(["terraform", "apply", "-auto-approve", "-input=false", "-no-color"], cwd=directory, capture_output=True, text=True)
                    self.assertEqual(apply.returncode, 0, apply.stdout + apply.stderr)
                    result = subprocess.run(["terraform", "output", "-json", "api_proxy"], cwd=directory, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout), expected)


if __name__ == "__main__":
    unittest.main()
