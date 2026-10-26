variable "name" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]+([._-][a-z0-9]+)*$", var.name))
    error_message = "Repository name must be lowercase letters, digits, and . _ - separators."
  }
}
variable "max_image_count" {
  description = "Tagged images to keep; older images are expired so promoted digests should stay within this window."
  type        = number
  default     = 30
}
