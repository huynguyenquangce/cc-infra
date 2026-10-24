# HTTPS certificate: request ACM first, then validate DNS before creating the ALB.
# Stage 1 requests a certificate without waiting for externally managed DNS.
# Request an HTTPS certificate for the API domain; the customer publishes the DNS validation CNAME.
resource "aws_acm_certificate" "api" {
  count             = var.existing_certificate_arn == null ? 1 : 0
  domain_name       = var.domain_name
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}
# Stage 2: customer has published the DNS validation CNAME, then enable_alb=true.
# Wait for ACM DNS validation before attaching the certificate to the ALB.
resource "aws_acm_certificate_validation" "api" {
  count                   = var.enable_alb && var.existing_certificate_arn == null ? 1 : 0
  certificate_arn         = aws_acm_certificate.api[0].arn
  validation_record_fqdns = [for option in aws_acm_certificate.api[0].domain_validation_options : option.resource_record_name]
  timeouts { create = "10m" }
}
locals {
  certificate_arn = var.existing_certificate_arn != null ? var.existing_certificate_arn : aws_acm_certificate.api[0].arn
}

# Network contract contains non-secret IDs; do not read raw VPN Terraform state.
# Read VPC/subnet IDs published by networking without reading VPN state directly.
data "aws_ssm_parameter" "network_contract" {
  count = var.enable_alb ? 1 : 0
  name  = "/cc/networking/contract"
}
locals {
  network           = var.enable_alb ? jsondecode(nonsensitive(data.aws_ssm_parameter.network_contract[0].value)) : null
  public_subnet_ids = var.enable_alb ? values(try(local.network.public_subnet_ids_by_environment["uat"], {})) : []
}
# Provision this environment's API Proxy after networking and the certificate are ready.
module "api_proxy" {
  count                        = var.enable_alb ? 1 : 0
  source                       = "../../modules/api-proxy"
  environment                  = "uat"
  aws_account_id               = var.aws_account_id
  aws_region                   = var.aws_region
  vpc_id                       = try(local.network.vpc_id, "")
  public_subnet_ids            = local.public_subnet_ids
  domain_name                  = var.domain_name
  certificate_arn              = local.certificate_arn
  backend_targets              = var.backend_targets
  alert_emails                 = var.alert_emails
  additional_alarm_action_arns = var.additional_alarm_action_arns
  allowed_client_cidrs         = var.allowed_client_cidrs
  enable_deletion_protection   = var.enable_deletion_protection
  force_destroy_logs           = var.force_destroy_logs
  log_retention_days           = var.log_retention_days
  idle_timeout_seconds         = var.idle_timeout_seconds
  health_check_path            = var.health_check_path
  minimum_healthy_targets      = var.minimum_healthy_targets
  error_count_threshold        = var.error_count_threshold
  latency_p95_seconds          = var.latency_p95_seconds
  depends_on                   = [aws_acm_certificate_validation.api]
}
