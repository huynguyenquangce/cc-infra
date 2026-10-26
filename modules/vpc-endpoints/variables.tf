variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "aws_region" { type = string }
variable "subnet_ids" {
  description = "Subnets that host the interface endpoint ENIs (one per AZ served)."
  type        = list(string)
  validation {
    condition     = length(var.subnet_ids) >= 1
    error_message = "Supply at least one subnet for interface endpoints."
  }
}
variable "route_table_ids" {
  description = "Route tables that receive the S3 gateway endpoint route (ECR image layers are stored in S3)."
  type        = list(string)
}
variable "interface_services" {
  type    = set(string)
  default = ["ecr.api", "ecr.dkr", "logs", "secretsmanager"]
}
