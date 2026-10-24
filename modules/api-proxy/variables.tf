variable "environment" {
  type = string
  validation {
    condition     = contains(["uat", "production"], var.environment)
    error_message = "Environment must be uat or production."
  }
}
variable "aws_account_id" { type = string }
variable "aws_region" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" {
  type = list(string)
  validation {
    condition     = length(distinct(var.public_subnet_ids)) >= 2
    error_message = "ALB requires at least two distinct public subnets (in separate AZs)."
  }
}
variable "domain_name" { type = string }
variable "certificate_arn" { type = string }
variable "backend_targets" {
  description = "Stable names mapped to private backend host IPs. Port on the host must expose HTTP 9010."
  type        = map(string)
  validation {
    condition = length(var.backend_targets) > 0 && alltrue([
      for ip in values(var.backend_targets) : can(regex("^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)", ip)) && can(cidrnetmask("${ip}/32"))
    ])
    error_message = "Supply at least one private RFC1918 IPv4 target; never register public VPN endpoint IPs."
  }
  validation {
    condition     = length(distinct(values(var.backend_targets))) == length(var.backend_targets)
    error_message = "Backend target IPs must be distinct."
  }
}
variable "allowed_client_cidrs" {
  type    = set(string)
  default = ["0.0.0.0/0"]
  validation {
    condition     = length(var.allowed_client_cidrs) > 0 && alltrue([for c in var.allowed_client_cidrs : can(cidrnetmask(c))])
    error_message = "Supply IPv4 CIDRs allowed to call the public listener."
  }
}
variable "enable_http_redirect" {
  type    = bool
  default = true
}
variable "enable_deletion_protection" {
  type    = bool
  default = true
}
variable "idle_timeout_seconds" {
  type    = number
  default = 60
  validation {
    condition     = var.idle_timeout_seconds >= 1 && var.idle_timeout_seconds <= 4000
    error_message = "ALB idle timeout must be 1–4000 seconds."
  }
}
variable "health_check_path" {
  type    = string
  default = "/health"
  validation {
    condition     = startswith(var.health_check_path, "/") && length(var.health_check_path) <= 1024
    error_message = "Health check path must start with / and contain at most 1024 characters."
  }
}
variable "health_check_interval_seconds" {
  type    = number
  default = 30
}
variable "health_check_timeout_seconds" {
  type    = number
  default = 5
}
variable "healthy_threshold" {
  type    = number
  default = 3
}
variable "unhealthy_threshold" {
  type    = number
  default = 3
}
variable "block_documentation" {
  type    = bool
  default = true
}
variable "log_retention_days" {
  type    = number
  default = 90
  validation {
    condition     = var.log_retention_days >= 1 && floor(var.log_retention_days) == var.log_retention_days
    error_message = "Log retention must be a positive integer in days."
  }
}
variable "force_destroy_logs" {
  type    = bool
  default = false
}
variable "alert_emails" {
  type    = set(string)
  default = []
}
variable "additional_alarm_action_arns" {
  type    = list(string)
  default = []
}
variable "minimum_healthy_targets" {
  type    = number
  default = 1
  validation {
    condition     = var.minimum_healthy_targets >= 1 && floor(var.minimum_healthy_targets) == var.minimum_healthy_targets && var.minimum_healthy_targets <= length(var.backend_targets)
    error_message = "Minimum healthy targets must be between 1 and the registered target count."
  }
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
