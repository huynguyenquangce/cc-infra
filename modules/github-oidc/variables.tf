variable "repository" {
  description = "Exact OWNER/REPO, case sensitive; no wildcards."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.repository))
    error_message = "Use exact OWNER/REPO."
  }
}
variable "existing_provider_arn" {
  type    = string
  default = null
}
variable "state_bucket_arn" { type = string }
variable "aws_region" { type = string }
variable "aws_account_id" { type = string }
