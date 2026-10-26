"""Execute workflow shell steps with a fake terraform binary; never call AWS."""
import json
import os
import shlex
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]

class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="cc-workflow-test-")
        self.addCleanup(self.directory.cleanup)
        self.work = Path(self.directory.name)
        bindir = self.work / "bin"
        bindir.mkdir()
        terraform = bindir / "terraform"
        terraform.write_text("""#!/usr/bin/env python3
import json, os, sys
with open(os.environ['CC_TEST_ARG_LOG'], 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:3] == ['show', '-json']:
    print(os.environ.get('CC_TEST_PLAN_JSON', '{"resource_changes": []}'))
""")
        terraform.chmod(0o755)
        self.log = self.work / "calls.jsonl"
        self.env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ["PATH"], CC_TEST_ARG_LOG=str(self.log), AWS_ACCOUNT_ID="123456789012", AWS_REGION="us-east-1", STATE_BUCKET="example-test-state")

    def read(self, name):
        return yaml.safe_load((ROOT / ".github/workflows" / name).read_text())

    def run_script(self, script, operation, environment="uat", confirmation=""):
        return subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script], cwd=self.work, env=dict(self.env, OPERATION=operation, DEPLOY_ENV=environment, DESTROY_CONFIRMATION=confirmation), text=True, capture_output=True)

    def test_application_environment_and_operation_matrix(self):
        workflow = self.read("application-infrastructure.yml")
        trigger = workflow.get("on", workflow.get(True))
        self.assertEqual(trigger["workflow_dispatch"]["inputs"]["environment"]["options"], ["uat", "production"])
        job = next(iter(workflow["jobs"].values()))
        self.assertIn('inputs.environment', job["environment"])
        self.assertIn('inputs.environment', workflow["concurrency"]["group"])
        self.assertFalse(workflow["concurrency"]["cancel-in-progress"])
        steps = job["steps"]
        guard = steps[0]
        auth_index = next(i for i, s in enumerate(steps) if "configure-aws-credentials@" in s.get("uses", ""))
        self.assertGreater(auth_index, 0)
        backend = next(s for s in steps if s.get("name") == "Initialize S3 backend")
        plan = next(s for s in steps if s.get("name") == "Create application plan for the selected operation")
        execute = next(s for s in steps if s.get("name") == "Execute the saved plan from this run")
        preflight = next(s for s in steps if s.get("name") == "Check ALB deletion protection before executing changes")
        self.assertLess(steps.index(preflight), steps.index(execute))
        self.assertEqual(preflight["if"], execute["if"])
        for environment in ["uat", "production"]:
            for operation in ["plan", "apply", "plan-destroy", "destroy"]:
                with self.subTest(environment=environment, operation=operation):
                    self.log.unlink(missing_ok=True)
                    confirmation = "destroy-" + environment if operation == "destroy" else ""
                    self.assertEqual(self.run_script(guard["run"], operation, environment, confirmation).returncode, 0)
                    self.assertEqual(self.run_script(backend["run"], operation, environment).returncode, 0)
                    result = self.run_script(plan["run"], operation, environment)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    should_execute = eval(execute["if"].replace("||", "or"), {"__builtins__": {}}, {"inputs": SimpleNamespace(operation=operation)})
                    self.assertEqual(should_execute, operation in ["apply", "destroy"])
                    if should_execute:
                        script = preflight["run"].replace("../../scripts/check-terraform-plan.py", shlex.quote(str(ROOT / "scripts/check-terraform-plan.py")))
                        result = self.run_script(script, operation, environment)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(self.run_script(execute["run"], operation, environment).returncode, 0)
                    calls = [json.loads(x) for x in self.log.read_text().splitlines()]
                    self.assertIn("-backend-config=key=" + environment + "/terraform.tfstate", calls[0])
                    self.assertEqual("-destroy" in calls[1], operation in ["plan-destroy", "destroy"])
                    self.assertEqual(len(calls), 4 if should_execute else 2)
                    if should_execute:
                        self.assertEqual(calls[2], ["show", "-json", "application.tfplan"])
                        self.assertEqual(calls[3][0], "apply")
                        self.assertEqual(calls[3][-1], "application.tfplan")

    def test_destroy_confirmation_cannot_cross_environments(self):
        guard = next(iter(self.read("application-infrastructure.yml")["jobs"].values()))["steps"][0]["run"]
        for environment, confirmation in [("production", "destroy-uat"), ("uat", "destroy-production"), ("uat", ""), ("production", "yes"), ("production", "destroy-production$(touch SHOULD_NOT_EXIST)")]:
            self.assertNotEqual(self.run_script(guard, "destroy", environment, confirmation).returncode, 0)
        self.assertFalse((self.work / "SHOULD_NOT_EXIST").exists())
        self.assertFalse(self.log.exists())

    def test_configuration_rejects_wrong_account_role_and_bucket(self):
        for file, environment in [("application-infrastructure.yml", "uat"), ("application-infrastructure.yml", "production"), ("networking.yml", "networking")]:
            job = next(iter(self.read(file)["jobs"].values()))
            script = next(s["run"] for s in job["steps"] if s.get("name") == "Check required configuration")
            correct = dict(self.env, DEPLOY_ENV=environment, ROLE_ARN=f"arn:aws:iam::123456789012:role/cc-terraform-{environment}", TFVARS_HCL='aws_account_id = "123456789012"')
            result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script], cwd=self.work, env=correct, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            tfvars = self.work / "terraform.tfvars"
            self.assertEqual(tfvars.stat().st_mode & 0o777, 0o600)
            tfvars.unlink()
            for invalid in [{"ROLE_ARN": "arn:aws:iam::123456789012:role/cc-terraform-other"}, {"AWS_ACCOUNT_ID": "wrong"}, {"STATE_BUCKET": "s3://my-state/path"}, {"TFVARS_HCL": ""}]:
                result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script], cwd=self.work, env=dict(correct, **invalid), text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(tfvars.exists())

    def test_networking_operation_matrix_and_confirmation(self):
        steps = next(iter(self.read("networking.yml")["jobs"].values()))["steps"]
        guard = steps[0]["run"]
        plan = next(s["run"] for s in steps if s.get("name") == "Create networking plan for the selected operation")
        backend = next(s["run"] for s in steps if s.get("name") == "Initialize S3 backend")
        for operation in ["plan", "apply", "plan-destroy", "destroy"]:
            self.log.unlink(missing_ok=True)
            self.assertEqual(self.run_script(guard, operation, "networking", "destroy-networking").returncode, 0)
            self.assertEqual(self.run_script(backend, operation, "networking").returncode, 0)
            self.assertEqual(self.run_script(plan, operation, "networking").returncode, 0)
            calls = [json.loads(x) for x in self.log.read_text().splitlines()]
            self.assertIn("-lockfile=readonly", calls[0])
            self.assertIn("-backend-config=key=networking/terraform.tfstate", calls[0])
            self.assertEqual("-destroy" in calls[1], operation in ["plan-destroy", "destroy"])
        self.assertNotEqual(self.run_script(guard, "destroy", "networking", "destroy-uat").returncode, 0)

    def test_plan_guard_blocks_protected_alb_and_invalid_plan_json(self):
        script = "python3 " + shlex.quote(str(ROOT / "scripts/check-terraform-plan.py")) + " application.tfplan"
        for actions in [["delete"], ["delete", "create"], ["create", "delete"]]:
            plan = {"resource_changes": [{"address": "module.api_proxy[0].aws_lb.this", "type": "aws_lb", "change": {"actions": actions, "before": {"enable_deletion_protection": True}}}]}
            self.env["CC_TEST_PLAN_JSON"] = json.dumps(plan)
            result = self.run_script(script, "destroy")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("First apply enable_deletion_protection=false", result.stderr)
        self.env["CC_TEST_PLAN_JSON"] = "not JSON"
        self.assertNotEqual(self.run_script(script, "destroy").returncode, 0)
        self.env["CC_TEST_PLAN_JSON"] = json.dumps({"resource_changes": [{"address": "module.api_proxy[0].aws_lb.this", "type": "aws_lb", "change": {"actions": ["delete"], "before": {"enable_deletion_protection": False}}}]})
        self.assertEqual(self.run_script(script, "destroy").returncode, 0)

    def test_shell_syntax(self):
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            for job in yaml.safe_load(path.read_text()).get("jobs", {}).values():
                for step in job.get("steps", []):
                    if "run" in step:
                        result = subprocess.run(["bash", "-n"], input=step["run"], text=True, capture_output=True)
                        self.assertEqual(result.returncode, 0, str(path) + result.stderr)

if __name__ == "__main__":
    unittest.main()
