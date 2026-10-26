# Network contract contains non-secret IDs; do not read raw VPN Terraform state.
# Read VPC/subnet IDs published by networking without reading VPN state directly.
data "aws_ssm_parameter" "network_contract" {
  count = var.enable_alb || var.enable_mcp ? 1 : 0
  name  = "/cc/networking/contract"
}
locals {
  network = length(data.aws_ssm_parameter.network_contract) > 0 ? jsondecode(nonsensitive(data.aws_ssm_parameter.network_contract[0].value)) : null
  # Internal ALBs and MCP tasks use the shared private subnets in both AZs; public subnets stay unused.
  alb_subnet_ids = var.enable_alb || var.enable_mcp ? values(try(local.network.subnet_ids, {})) : []
}
# API Proxy: CloudFront (default HTTPS) -> VPC origin -> internal ALB -> Commerce backends over VPN.
module "api_proxy" {
  count                        = var.enable_alb ? 1 : 0
  source                       = "../../modules/api-proxy"
  environment                  = "production"
  aws_account_id               = var.aws_account_id
  aws_region                   = var.aws_region
  vpc_id                       = try(local.network.vpc_id, "")
  alb_subnet_ids               = local.alb_subnet_ids
  backend_targets              = var.backend_targets
  alert_emails                 = var.alert_emails
  additional_alarm_action_arns = var.additional_alarm_action_arns
  enable_deletion_protection   = var.enable_deletion_protection
  force_destroy_logs           = var.force_destroy_logs
  log_retention_days           = var.log_retention_days
  idle_timeout_seconds         = var.idle_timeout_seconds
  health_check_path            = var.health_check_path
  minimum_healthy_targets      = var.minimum_healthy_targets
  error_count_threshold        = var.error_count_threshold
  latency_p95_seconds          = var.latency_p95_seconds
}

# MCP Server: CloudFront (default HTTPS) -> VPC origin -> internal ALB -> Fargate spread over both private subnets.
module "mcp_server" {
  count                        = var.enable_mcp ? 1 : 0
  source                       = "../../modules/mcp-server"
  environment                  = "production"
  aws_account_id               = var.aws_account_id
  aws_region                   = var.aws_region
  vpc_id                       = try(local.network.vpc_id, "")
  alb_subnet_ids               = local.alb_subnet_ids
  service_subnet_ids           = local.alb_subnet_ids
  endpoint_security_group_id   = try(local.network.vpc_endpoint_security_group_id, null)
  s3_prefix_list_id            = try(local.network.s3_prefix_list_id, null)
  initial_image                = var.mcp_initial_image
  run_service                  = var.mcp_run_service
  enabled_features             = var.mcp_enabled_features
  app_environment              = var.mcp_app_environment
  vendor_egress_cidrs          = var.mcp_vendor_egress_cidrs
  vpn_egress_targets           = var.mcp_vpn_egress_targets
  min_tasks                    = var.mcp_min_tasks
  max_tasks                    = var.mcp_max_tasks
  log_retention_days           = var.mcp_log_retention_days
  enable_deletion_protection   = var.enable_deletion_protection
  force_destroy_logs           = var.force_destroy_logs
  alert_emails                 = var.alert_emails
  additional_alarm_action_arns = var.additional_alarm_action_arns
}
