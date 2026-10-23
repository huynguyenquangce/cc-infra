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

variable "state_bucket_name" { type = string }
variable "github_repository" { type = string }
variable "existing_github_oidc_provider_arn" {
  type    = string
  default = null
}
