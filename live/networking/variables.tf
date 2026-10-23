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
