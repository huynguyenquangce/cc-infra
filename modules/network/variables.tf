variable "vpc_cidr" { type = string }
variable "private_subnets" {
  type = map(object({ cidr = string, availability_zone = string }))
}

variable "nat_subnet" {
  description = "Optional shared public subnet hosting one NAT gateway for private-subnet internet egress."
  type        = object({ cidr = string, availability_zone = string })
  default     = null
  validation {
    condition     = var.nat_subnet == null || try(can(cidrnetmask(var.nat_subnet.cidr)) && tonumber(split("/", var.nat_subnet.cidr)[1]) <= 28, false)
    error_message = "NAT subnet requires an IPv4 CIDR of /28 or larger."
  }
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
