mock_provider "aws" {
  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "{\"version\":3,\"vpc_id\":\"vpc-0123456789abcdef0\",\"subnet_ids\":{\"private-a\":\"subnet-4123456789abcdef0\",\"private-b\":\"subnet-5123456789abcdef0\"},\"public_subnet_ids_by_environment\":{\"uat\":{\"a\":\"subnet-0123456789abcdef0\",\"b\":\"subnet-1123456789abcdef0\"},\"production\":{\"a\":\"subnet-2123456789abcdef0\",\"b\":\"subnet-3123456789abcdef0\"}},\"vpc_endpoint_security_group_id\":\"sg-0123456789abcdef0\",\"s3_prefix_list_id\":\"pl-63a5400a\"}"
    }
  }
}
variables {
  aws_account_id = "123456789012"
}
run "nothing_is_created_until_enabled" {
  command = plan
  assert {
    condition     = length(module.api_proxy) == 0 && length(module.mcp_server) == 0 && length(data.aws_ssm_parameter.network_contract) == 0
    error_message = "Both applications must stay off (and skip the contract read) until explicitly enabled."
  }
  assert {
    condition     = length(output.api_proxy) == 0 && length(output.mcp_server) == 0
    error_message = "Disabled applications must expose empty objects, not omitted null outputs."
  }
}
run "api_proxy_uses_shared_private_subnets_not_public" {
  command = plan
  variables {
    enable_alb      = true
    backend_targets = { first = "172.19.16.23", second = "172.19.16.24" }
    alert_emails    = ["ops@example.com"]
  }
  assert {
    condition     = length(module.api_proxy) == 1 && length(module.mcp_server) == 0 && length(local.alb_subnet_ids) == 2 && contains(local.alb_subnet_ids, "subnet-4123456789abcdef0") && contains(local.alb_subnet_ids, "subnet-5123456789abcdef0")
    error_message = "The internal API Proxy ALB must use both shared private subnets."
  }
  assert {
    condition     = !contains(local.alb_subnet_ids, "subnet-0123456789abcdef0") && !contains(local.alb_subnet_ids, "subnet-2123456789abcdef0")
    error_message = "Public subnets stay in place but must not host the internal ALB."
  }
}
run "mcp_tasks_spread_over_both_private_subnets" {
  command = plan
  variables {
    enable_mcp        = true
    mcp_run_service   = true
    mcp_initial_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/cc-mcp-server@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    alert_emails      = ["ops@example.com"]
  }
  assert {
    condition     = length(module.mcp_server) == 1 && length(module.api_proxy) == 0 && length(local.alb_subnet_ids) == 2 && contains(local.alb_subnet_ids, "subnet-4123456789abcdef0") && contains(local.alb_subnet_ids, "subnet-5123456789abcdef0")
    error_message = "MCP tasks of production must be spread over both private subnets (two AZs)."
  }
}
run "mcp_requires_initial_image" {
  command = plan
  variables {
    enable_mcp   = true
    alert_emails = ["ops@example.com"]
  }
  expect_failures = [var.mcp_initial_image]
}
run "enabled_application_requires_alert_recipient" {
  command = plan
  variables {
    enable_alb      = true
    backend_targets = { first = "172.19.16.23" }
  }
  expect_failures = [var.additional_alarm_action_arns]
}
