mock_provider "aws" {
  mock_data "aws_ec2_managed_prefix_list" {
    defaults = { id = "pl-3b927c52" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:cc-mcp/uat/vendor-AbCdEf" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/cc-uat-mcp/0123456789abcdef", dns_name = "internal-cc-uat-mcp-123.us-east-1.elb.amazonaws.com" }
  }
}
variables {
  environment                = "uat"
  aws_account_id             = "123456789012"
  aws_region                 = "us-east-1"
  vpc_id                     = "vpc-0123456789abcdef0"
  alb_subnet_ids             = ["subnet-0123456789abcdef0", "subnet-1123456789abcdef0"]
  service_subnet_ids         = ["subnet-0123456789abcdef0"]
  endpoint_security_group_id = "sg-0123456789abcdef0"
  s3_prefix_list_id          = "pl-63a5400a"
  initial_image              = "123456789012.dkr.ecr.us-east-1.amazonaws.com/cc-mcp-server@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  app_environment            = { MCP_AUTH_ISSUER = "https://gateway.example/", SQUIRREL_BASE_URL = "https://api.squirrel.example" }
}
run "internal_alb_behind_cloudfront_vpc_origin" {
  command = plan
  assert {
    condition     = aws_lb.this.internal && aws_lb_listener.http.port == 80 && aws_lb_target_group.this.port == 8000 && aws_lb_target_group.this.health_check[0].path == "/readyz"
    error_message = "MCP ALB must be internal HTTP :80 forwarding to tasks on 8000 with /readyz health checks."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_from_cloudfront.prefix_list_id == "pl-3b927c52" && aws_vpc_security_group_ingress_rule.alb_from_cloudfront.cidr_ipv4 == null
    error_message = "ALB ingress must come only from the CloudFront origin-facing prefix list."
  }
  assert {
    condition     = module.cloudfront.endpoint != null
    error_message = "CloudFront must serve HTTPS only with the default *.cloudfront.net certificate."
  }
}
run "endpoint_and_image_from_parameter" {
  command = plan
  override_resource {
    target          = module.cloudfront.aws_cloudfront_distribution.this
    override_during = plan
    values          = { domain_name = "d111111abcdef8.cloudfront.net" }
  }
  assert {
    condition     = output.endpoint == "https://d111111abcdef8.cloudfront.net"
    error_message = "Endpoint must be the CloudFront HTTPS URL."
  }
  assert {
    condition     = nonsensitive(aws_ssm_parameter.image.value) == var.initial_image && aws_ssm_parameter.image.name == "/cc/uat/mcp/image"
    error_message = "The image parameter must be seeded from initial_image at /cc/<env>/mcp/image."
  }
}
run "only_enabled_vendor_secrets_are_injected" {
  command = plan
  assert {
    condition     = length(aws_secretsmanager_secret.vendor) == 3 && length(local.container_secrets) == 3 && alltrue([for s in local.container_secrets : startswith(s.name, "SQUIRREL_")])
    error_message = "All three secrets exist, but only Squirrel credentials are injected when only squirrel is enabled."
  }
  assert {
    condition     = local.container_environment["COMMERCE_ENABLED_FEATURES"] == "squirrel" && !contains(keys(local.container_environment), "SQUIRREL_CLIENT_SECRET")
    error_message = "Feature list comes from enabled_features and secrets never appear as plain environment."
  }
}
run "genesis_adds_its_secrets_and_vpn_egress" {
  command = plan
  variables {
    enabled_features   = ["squirrel", "genesis"]
    vpn_egress_targets = { genesis = { cidr = "172.19.16.50/32", port = 443 } }
  }
  assert {
    condition     = length(local.container_secrets) == 5 && local.container_environment["COMMERCE_ENABLED_FEATURES"] == "squirrel,genesis"
    error_message = "Enabling genesis must inject its two secrets."
  }
  assert {
    condition     = aws_vpc_security_group_egress_rule.service_to_vpn["genesis"].cidr_ipv4 == "172.19.16.50/32" && aws_vpc_security_group_egress_rule.service_to_vpn["genesis"].from_port == 443
    error_message = "VPN egress must be limited to the configured Commerce target."
  }
}
run "service_can_wait_for_secret_values" {
  command = plan
  variables {
    run_service = false
  }
  assert {
    condition     = length(aws_ecs_service.this) == 0 && length(aws_appautoscaling_target.this) == 0 && length(aws_secretsmanager_secret.vendor) == 3 && length(local.service_alarms) == 0
    error_message = "run_service=false must create secrets and edge resources without starting tasks or alarming."
  }
}
run "service_rolls_back_and_scales" {
  command = plan
  variables {
    min_tasks = 1
    max_tasks = 3
  }
  assert {
    condition     = aws_ecs_service.this[0].deployment_circuit_breaker[0].rollback && aws_ecs_service.this[0].deployment_minimum_healthy_percent == 100 && !aws_ecs_service.this[0].network_configuration[0].assign_public_ip
    error_message = "Service must roll back failed deployments, keep capacity during rollout, and stay private."
  }
  assert {
    condition     = aws_appautoscaling_target.this[0].min_capacity == 1 && aws_appautoscaling_target.this[0].max_capacity == 3
    error_message = "Auto scaling bounds must follow min_tasks and max_tasks."
  }
}
run "reject_mutable_image_tag" {
  command = plan
  variables {
    initial_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/cc-mcp-server:latest"
  }
  expect_failures = [var.initial_image]
}
run "reject_disabled_caller_auth" {
  command = plan
  variables {
    app_environment = { MCP_AUTH_ENABLED = "False" }
  }
  expect_failures = [var.app_environment]
}
run "reject_secret_in_plain_environment" {
  command = plan
  variables {
    app_environment = { GENESIS_API_PASS = "oops" }
  }
  expect_failures = [var.app_environment]
}
run "pinned_gateway_key_comes_from_the_auth_secret" {
  command = plan
  variables {
    auth_public_key_from_secret = true
    app_environment             = { MCP_AUTH_ISSUER = "https://gateway.example/", MCP_AUTH_ALGORITHMS = "HS256", SQUIRREL_BASE_URL = "https://api.squirrel.example" }
  }
  assert {
    condition     = length(local.container_secrets) == 4 && contains([for s in local.container_secrets : s.name], "MCP_AUTH_PUBLIC_KEY")
    error_message = "With auth_public_key_from_secret the pinned key must be injected from cc-mcp/<env>/auth."
  }
}
run "reject_public_key_in_plain_environment" {
  command = plan
  variables {
    app_environment = { MCP_AUTH_PUBLIC_KEY = "shared-hs256-key" }
  }
  expect_failures = [var.app_environment]
}
run "reject_jwks_url_together_with_secret_key" {
  command = plan
  variables {
    auth_public_key_from_secret = true
    app_environment             = { MCP_AUTH_JWKS_URL = "https://gateway.example/.well-known/jwks.json", MCP_AUTH_ISSUER = "https://gateway.example/" }
  }
  expect_failures = [var.auth_public_key_from_secret]
}
run "reject_unknown_feature" {
  command = plan
  variables {
    enabled_features = ["squirrel", "opentable"]
  }
  expect_failures = [var.enabled_features]
}
run "reject_public_vpn_target" {
  command = plan
  variables {
    vpn_egress_targets = { genesis = { cidr = "66.215.9.236/32", port = 443 } }
  }
  expect_failures = [var.vpn_egress_targets]
}
