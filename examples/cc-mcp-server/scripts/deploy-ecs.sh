#!/usr/bin/env bash
# Roll an ECR image (by digest) out to cc-<env>-mcp and record it for Terraform.
# Usage: deploy-ecs.sh <uat|production> <registry/repo@sha256:...> [https://endpoint]
set -euo pipefail
environment="$1"
image="$2"
endpoint="${3:-}"
name="cc-${environment}-mcp"
case "$environment" in uat|production) ;; *) echo "Unsupported environment: $environment" >&2; exit 1 ;; esac
[[ "$image" =~ @sha256:[a-f0-9]{64}$ ]] || { echo "Image must be pinned by digest: $image" >&2; exit 1; }

# Start from the latest revision (Terraform-managed settings) and change only the image.
aws ecs describe-task-definition --task-definition "$name" --query taskDefinition --output json \
  | IMAGE="$image" python3 -c '
import json, os, sys
task = json.load(sys.stdin)
for key in ["taskDefinitionArn", "revision", "status", "requiresAttributes", "compatibilities", "registeredAt", "registeredBy", "deregisteredAt"]:
    task.pop(key, None)
containers = [c for c in task["containerDefinitions"] if c["name"] == "mcp-server"]
if len(containers) != 1:
    sys.exit("Task definition has no mcp-server container")
containers[0]["image"] = os.environ["IMAGE"]
json.dump(task, sys.stdout)
' > task-definition.json
revision="$(aws ecs register-task-definition --cli-input-json file://task-definition.json --query taskDefinition.taskDefinitionArn --output text)"
echo "Registered $revision"

aws ecs update-service --cluster "$name" --service "$name" --task-definition "$revision" >/dev/null
aws ecs wait services-stable --cluster "$name" --services "$name"

# The circuit breaker may have rolled back; a stable service on the old revision is a failed release.
running="$(aws ecs describe-services --cluster "$name" --services "$name" --query 'services[0].taskDefinition' --output text)"
[[ "$running" == "$revision" ]] || { echo "Deployment rolled back to $running" >&2; exit 1; }

# Record the release only after it is healthy, so later Terraform applies render this image.
aws ssm put-parameter --name "/cc/${environment}/mcp/image" --type String --value "$image" --overwrite >/dev/null

if [[ -n "$endpoint" ]]; then
  curl --fail --silent --show-error --max-time 10 --retry 5 --retry-delay 5 "${endpoint}/readyz"
  echo
fi
echo "Deployed $image to $name"
