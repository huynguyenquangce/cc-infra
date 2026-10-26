variable "aws_account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Supply the AWS account ID (12 digits)."
  }
}
variable "aws_region" {
  type    = string
  default = "us-east-1"
}
variable "enable_alb" {
  description = "Create the API Proxy (CloudFront, internal ALB, backend targets, monitoring)."
  type        = bool
  default     = false
}
variable "backend_targets" {
  description = "Stable server name -> private host IP. HTTP 9010 must be published by Commerce."
  type        = map(string)
  default     = {}
  validation {
    condition     = !var.enable_alb || length(var.backend_targets) > 0
    error_message = "Supply confirmed backend targets before enabling ALB."
  }
}
variable "alert_emails" {
  type    = set(string)
  default = []
  validation {
    condition     = alltrue([for email in var.alert_emails : can(regex("^[^@ ]+@[^@ ]+[.][^@ ]+$", email))])
    error_message = "Supply valid email addresses for alarm subscriptions."
  }
}
variable "additional_alarm_action_arns" {
  type    = list(string)
  default = []
  validation {
    condition     = !(var.enable_alb || var.enable_mcp) || length(var.alert_emails) + length(var.additional_alarm_action_arns) > 0
    error_message = "Enabling ALB or MCP requires an alarm email recipient or existing SNS action ARN."
  }
  validation {
    condition     = alltrue([for arn in var.additional_alarm_action_arns : can(regex("^arn:aws:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$", arn))])
    error_message = "Additional alarm actions must be standard SNS topic ARNs."
  }
}
variable "enable_deletion_protection" {
  type    = bool
  default = true
}
variable "force_destroy_logs" {
  type    = bool
  default = false
}
variable "log_retention_days" {
  type    = number
  default = 90
}
variable "idle_timeout_seconds" {
  type    = number
  default = 60
}
variable "health_check_path" {
  type    = string
  default = "/health"
  validation {
    condition     = startswith(var.health_check_path, "/") && length(var.health_check_path) <= 1024
    error_message = "Health check path must start with / and contain at most 1024 characters."
  }
}
variable "minimum_healthy_targets" {
  type    = number
  default = 1
}
variable "error_count_threshold" {
  type    = number
  default = 5
  validation {
    condition     = var.error_count_threshold >= 1 && floor(var.error_count_threshold) == var.error_count_threshold
    error_message = "Error count threshold must be a positive integer."
  }
}
variable "latency_p95_seconds" {
  type    = number
  default = 2
  validation {
    condition     = var.latency_p95_seconds > 0
    error_message = "Latency threshold must be greater than zero."
  }
}

# MCP Server inputs. Secrets are never variables: fill cc-mcp/production/* with put-secret-value.
variable "enable_mcp" {
  description = "Create the MCP edge (CloudFront, internal ALB), secrets, image parameter, and ECS cluster/task definition."
  type        = bool
  default     = false
}
variable "mcp_run_service" {
  description = "Start the ECS service. Keep false until cc-mcp/production/* secrets have values."
  type        = bool
  default     = false
}
variable "mcp_initial_image" {
  description = "First pushed image by digest; seeds /cc/production/mcp/image (the application CI owns it afterwards)."
  type        = string
  default     = null
  validation {
    condition     = !var.enable_mcp || var.mcp_initial_image != null
    error_message = "Push the first image to ECR and supply mcp_initial_image (by digest) before enabling MCP."
  }
}
variable "mcp_enabled_features" {
  type    = list(string)
  default = ["squirrel"]
}
variable "mcp_app_environment" {
  description = "Non-secret container settings: MCP_AUTH_*, SQUIRREL_BASE_URL, GENESIS_BASE_URL, GENESIS_TIMEZONE, LOG_LEVEL."
  type        = map(string)
  default     = {}
}
variable "mcp_auth_public_key_from_secret" {
  description = "true: MCP_AUTH_PUBLIC_KEY comes from cc-mcp/<env>/auth (needed when Commerce signs with HS256); omit MCP_AUTH_JWKS_URL."
  type        = bool
  default     = false
}
variable "mcp_vendor_egress_cidrs" {
  type    = set(string)
  default = ["0.0.0.0/0"]
}
variable "mcp_vpn_egress_targets" {
  type    = map(object({ cidr = string, port = number }))
  default = {}
}
variable "mcp_min_tasks" {
  description = "Production keeps at least two tasks so both AZs always serve traffic."
  type        = number
  default     = 2
}
variable "mcp_max_tasks" {
  type    = number
  default = 3
}
variable "mcp_log_retention_days" {
  type    = number
  default = 90
}
