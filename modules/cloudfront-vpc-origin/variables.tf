variable "name" {
  description = "VPC origin name, e.g. cc-uat-mcp."
  type        = string
}
variable "comment" { type = string }
variable "alb_arn" {
  description = "Internal ALB that CloudFront reaches through the VPC origin."
  type        = string
}
variable "alb_dns_name" { type = string }
variable "origin_read_timeout_seconds" {
  description = "CloudFront wait for the ALB response; 60 is the maximum without a quota increase."
  type        = number
  default     = 30
  validation {
    condition     = var.origin_read_timeout_seconds >= 1 && var.origin_read_timeout_seconds <= 60
    error_message = "Origin read timeout must be 1-60 seconds."
  }
}
variable "price_class" {
  type    = string
  default = "PriceClass_100"
}
