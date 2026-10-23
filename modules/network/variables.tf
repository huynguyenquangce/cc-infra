variable "vpc_cidr" { type = string }
variable "private_subnets" {
  type = map(object({ cidr = string, availability_zone = string }))
}
