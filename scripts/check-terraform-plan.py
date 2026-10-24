"""Reject protected ALB deletion before Terraform can partially execute a plan."""
import json
import subprocess
import sys


def protected_deletions(plan):
    return [
        change["address"]
        for change in plan.get("resource_changes", [])
        if change.get("mode", "managed") == "managed"
        and change.get("type") == "aws_lb"
        and "delete" in change.get("change", {}).get("actions", [])
        and (change["change"].get("before") or {}).get("enable_deletion_protection", False)
    ]


def main():
    if len(sys.argv) != 2:
        print("Usage: check-terraform-plan.py PLAN_FILE", file=sys.stderr)
        return 2
    result = subprocess.run(["terraform", "show", "-json", sys.argv[1]], capture_output=True, text=True)
    if result.returncode:
        print("Cannot inspect saved Terraform plan; refusing to execute it.", file=sys.stderr)
        return result.returncode
    try:
        protected = protected_deletions(json.loads(result.stdout))
    except (ValueError, KeyError, TypeError):
        print("Invalid Terraform plan JSON; refusing to execute it.", file=sys.stderr)
        return 1
    if protected:
        print("Plan would delete or replace an ALB with deletion protection enabled:", file=sys.stderr)
        for address in protected:
            print("  " + address, file=sys.stderr)
        print("First apply enable_deletion_protection=false while keeping enable_alb=true, then create a new destroy/replacement plan.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
