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
  type = map(object({ cidr = string, availability_zone = string }))
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
