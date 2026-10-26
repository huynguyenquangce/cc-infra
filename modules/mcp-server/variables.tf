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
variable "alb_subnet_ids" {
  description = "Private subnets for the internal ALB; must span at least two AZs supported by CloudFront VPC origins."
  type        = list(string)
  validation {
    condition     = length(distinct(var.alb_subnet_ids)) >= 2
    error_message = "Internal ALB requires at least two distinct private subnets (in separate AZs)."
  }
}
variable "service_subnet_ids" {
  description = "Private subnets assigned to this environment's ECS tasks (source IPs Commerce allowlists over VPN)."
  type        = list(string)
  validation {
    condition     = length(var.service_subnet_ids) >= 1
    error_message = "Assign at least one private subnet to this environment (networking private_subnets[*].environment)."
  }
}
variable "endpoint_security_group_id" {
  description = "Security group of the shared VPC interface endpoints (networking contract v3)."
  type        = string
  nullable    = false
}
variable "s3_prefix_list_id" {
  description = "Prefix list of the S3 gateway endpoint, for ECR image layers (networking contract v3)."
  type        = string
  nullable    = false
}
variable "ecr_repository_name" {
  type    = string
  default = "cc-mcp-server"
}
variable "initial_image" {
  description = "First image, pinned by digest. Seeds /cc/<env>/mcp/image; afterwards the application CI owns that parameter."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}[.]dkr[.]ecr[.][a-z0-9-]+[.]amazonaws[.]com/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$", var.initial_image))
    error_message = "Use an ECR image pinned by digest: <account>.dkr.ecr.<region>.amazonaws.com/<repo>@sha256:<64 hex>."
  }
}
variable "run_service" {
  description = "false creates everything except the ECS service, so vendor secrets can be filled before the first task starts."
  type        = bool
  default     = true
}
variable "enabled_features" {
  description = "MCP servers to mount (COMMERCE_ENABLED_FEATURES); only their vendor secrets are injected."
  type        = list(string)
  default     = ["squirrel"]
  validation {
    condition     = length(var.enabled_features) > 0 && alltrue([for f in var.enabled_features : contains(["squirrel", "genesis"], f)]) && length(distinct(var.enabled_features)) == length(var.enabled_features)
    error_message = "Enabled features must be a non-empty, distinct subset of squirrel and genesis."
  }
}
variable "app_environment" {
  description = "Non-secret container environment (MCP_AUTH_*, *_BASE_URL, timeouts, GENESIS_TIMEZONE, LOG_LEVEL)."
  type        = map(string)
  default     = {}
  validation {
    condition = length(setintersection(keys(var.app_environment), [
      "SQUIRREL_CLIENT_ID", "SQUIRREL_CLIENT_SECRET", "SQUIRREL_WEBHOOK_SECRET", "GENESIS_API_PASS", "GENESIS_CASINO_ID", "MCP_AUTH_PUBLIC_KEY", "COMMERCE_ENABLED_FEATURES"
    ])) == 0
    error_message = "Credentials and MCP_AUTH_PUBLIC_KEY come from Secrets Manager and COMMERCE_ENABLED_FEATURES from enabled_features; remove them from app_environment."
  }
  validation {
    condition     = lower(lookup(var.app_environment, "MCP_AUTH_ENABLED", "true")) != "false"
    error_message = "MCP_AUTH_ENABLED=false is for local development only; deployed environments must authenticate callers."
  }
}
variable "auth_public_key_from_secret" {
  description = "Inject MCP_AUTH_PUBLIC_KEY from cc-mcp/<env>/auth (key public_key) instead of using MCP_AUTH_JWKS_URL; required for HS256."
  type        = bool
  default     = false
  validation {
    condition     = !(var.auth_public_key_from_secret && contains(keys(var.app_environment), "MCP_AUTH_JWKS_URL"))
    error_message = "The application accepts exactly one of MCP_AUTH_JWKS_URL or MCP_AUTH_PUBLIC_KEY; remove MCP_AUTH_JWKS_URL when the key comes from the secret."
  }
}
variable "vendor_egress_cidrs" {
  description = "Internet destinations (via NAT) the tasks may call on HTTPS, e.g. Squirrel."
  type        = set(string)
  default     = ["0.0.0.0/0"]
  validation {
    condition     = alltrue([for c in var.vendor_egress_cidrs : can(cidrnetmask(c))])
    error_message = "Vendor egress entries must be IPv4 CIDRs."
  }
}
variable "vpn_egress_targets" {
  description = "Commerce destinations over the Site-to-Site VPN, e.g. { genesis = { cidr = \"172.19.16.50/32\", port = 443 } }."
  type        = map(object({ cidr = string, port = number }))
  default     = {}
  validation {
    condition = alltrue([for t in values(var.vpn_egress_targets) :
      can(regex("^(10[.]|172[.](1[6-9]|2[0-9]|3[01])[.]|192[.]168[.])", t.cidr)) && can(cidrnetmask(t.cidr)) && t.port >= 1 && t.port <= 65535
    ])
    error_message = "VPN targets must be private RFC1918 CIDRs with a valid port."
  }
}
variable "task_cpu" {
  type    = number
  default = 2048
}
variable "task_memory" {
  type    = number
  default = 8192
}
variable "min_tasks" {
  type    = number
  default = 1
  validation {
    condition     = var.min_tasks >= 1 && floor(var.min_tasks) == var.min_tasks
    error_message = "Minimum task count must be a positive integer."
  }
}
variable "max_tasks" {
  type    = number
  default = 2
  validation {
    condition     = var.max_tasks >= var.min_tasks && floor(var.max_tasks) == var.max_tasks
    error_message = "Maximum task count must be an integer no lower than min_tasks."
  }
}
variable "cpu_target_percent" {
  type    = number
  default = 50
}
variable "health_check_path" {
  type    = string
  default = "/readyz"
  validation {
    condition     = startswith(var.health_check_path, "/")
    error_message = "Health check path must start with /."
  }
}
variable "block_documentation" {
  type    = bool
  default = true
}
variable "origin_read_timeout_seconds" {
  description = "CloudFront wait for the ALB response; 60 is the maximum without a quota increase."
  type        = number
  default     = 30
  validation {
    condition     = var.origin_read_timeout_seconds >= 1 && var.origin_read_timeout_seconds <= 60
    error_message = "Origin read timeout must be 1-60 seconds."
  }
}
variable "cloudfront_price_class" {
  type    = string
  default = "PriceClass_100"
}
variable "enable_deletion_protection" {
  type    = bool
  default = true
}
variable "log_retention_days" {
  type    = number
  default = 30
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "Use a CloudWatch Logs retention value (e.g. 30 or 90)."
  }
}
variable "force_destroy_logs" {
  type    = bool
  default = false
}
variable "secret_recovery_window_days" {
  type    = number
  default = 7
}
variable "alert_emails" {
  type    = set(string)
  default = []
}
variable "additional_alarm_action_arns" {
  type    = list(string)
  default = []
}
variable "error_count_threshold" {
  type    = number
  default = 5
}
variable "latency_p99_seconds" {
  type    = number
  default = 10
}
