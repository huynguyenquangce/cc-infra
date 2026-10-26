variable "repository" {
  description = "Exact OIDC OWNER/REPO segment, including @IDs when GitHub uses immutable subjects; no wildcards."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+(@[0-9]+)?/[A-Za-z0-9_.-]+(@[0-9]+)?$", var.repository))
    error_message = "Use exact OWNER/REPO or OWNER@ID/REPO@ID from the GitHub OIDC subject."
  }
}
variable "existing_provider_arn" {
  type    = string
  default = null
}
variable "state_bucket_arn" { type = string }
variable "aws_region" { type = string }
variable "aws_account_id" { type = string }
variable "mcp_app_repository" {
  description = "Exact OWNER/REPO (or OWNER@ID/REPO@ID) of cc-mcp-server for its push/deploy roles; null creates none."
  type        = string
  default     = null
  validation {
    condition     = var.mcp_app_repository == null || can(regex("^[A-Za-z0-9_.-]+(@[0-9]+)?/[A-Za-z0-9_.-]+(@[0-9]+)?$", coalesce(var.mcp_app_repository, "-")))
    error_message = "Use exact OWNER/REPO or OWNER@ID/REPO@ID from the GitHub OIDC subject."
  }
}
variable "mcp_ecr_repository_name" {
  type    = string
  default = "cc-mcp-server"
}
