variable "aws_region" {
  type    = string
  default = "us-east-1"
}
variable "aws_account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "AWS account ID must contain 12 digits."
  }
}

variable "vpc_cidr" { type = string }
variable "private_subnets" {
  description = "Private subnets shared by both environments' internal ALBs and MCP tasks."
  type        = map(object({ cidr = string, availability_zone = string }))
}
variable "nat_subnet" {
  description = "Optional public subnet for one shared NAT gateway; null keeps private subnets without internet egress."
  type        = object({ cidr = string, availability_zone = string })
  default     = null
}
variable "vpc_endpoint_subnet_keys" {
  description = "private_subnets keys hosting interface endpoints (ECR, Logs, Secrets Manager); empty creates no endpoints."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for k in var.vpc_endpoint_subnet_keys : contains(keys(var.private_subnets), k)])
    error_message = "VPC endpoint subnet keys must reference private_subnets entries."
  }
}
variable "ecr_repositories" {
  description = "Shared ECR repositories, e.g. [\"cc-mcp-server\"]."
  type        = set(string)
  default     = []
}
variable "amazon_side_asn" { type = number }
variable "customer_gateways" { type = map(object({ ip_address = string, bgp_asn = number })) }
variable "alarm_action_arns" {
  type    = list(string)
  default = []
}
variable "phase1_lifetime_seconds" {
  type    = number
  default = 28800
}
variable "phase2_lifetime_seconds" {
  type    = number
  default = 3600
}

variable "public_subnets" {
  description = "Optional ALB subnets. Existing deployments remain unchanged until entries are supplied."
  type        = map(object({ cidr = string, availability_zone = string, environment = string }))
  default     = {}
  validation {
    condition     = alltrue([for s in values(var.public_subnets) : contains(["uat", "production"], s.environment) && can(cidrnetmask(s.cidr)) && try(tonumber(split("/", s.cidr)[1]) <= 27, false)])
    error_message = "Public ALB subnets require an IPv4 CIDR of /27 or larger and environment uat or production."
  }
  validation {
    condition = alltrue([for env in ["uat", "production"] :
      length([for s in values(var.public_subnets) : s if s.environment == env]) == 0 ||
      (length([for s in values(var.public_subnets) : s if s.environment == env]) >= 2 &&
      length(distinct([for s in values(var.public_subnets) : s.availability_zone if s.environment == env])) == length([for s in values(var.public_subnets) : s if s.environment == env]))
    ])
    error_message = "Provide at least two public ALB subnets per enabled environment, with exactly one subnet per AZ."
  }
}
