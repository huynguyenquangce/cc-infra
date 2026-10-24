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
variable "domain_name" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*[.][a-z]{2,}$", var.domain_name)) && !strcontains(var.domain_name, "..")
    error_message = "Supply a lowercase public API hostname, without https:// or a path."
  }
}
variable "enable_alb" {
  description = "false: request ACM only; true: after DNS validation, provision ALB and monitoring."
  type        = bool
  default     = false
}
variable "existing_certificate_arn" {
  description = "Optional already-issued ACM certificate in this account/region covering domain_name."
  type        = string
  default     = null
  validation {
    condition     = var.existing_certificate_arn == null ? true : startswith(var.existing_certificate_arn, "arn:aws:acm:${var.aws_region}:${var.aws_account_id}:certificate/")
    error_message = "Existing ACM certificate must be in the deployment account and region."
  }
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
    condition     = !var.enable_alb || length(var.alert_emails) + length(var.additional_alarm_action_arns) > 0
    error_message = "Enabling ALB requires an alarm email recipient or existing SNS action ARN."
  }
  validation {
    condition     = alltrue([for arn in var.additional_alarm_action_arns : can(regex("^arn:aws:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$", arn))])
    error_message = "Additional alarm actions must be standard SNS topic ARNs."
  }
}
variable "allowed_client_cidrs" {
  type    = set(string)
  default = ["0.0.0.0/0"]
}
variable "enable_deletion_protection" {
  type    = bool
  default = false
}
variable "force_destroy_logs" {
  type    = bool
  default = false
}
variable "log_retention_days" {
  type    = number
  default = 30
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
