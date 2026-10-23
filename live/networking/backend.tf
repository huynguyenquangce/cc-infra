terraform {
  backend "s3" {
    # Keep backend workspace-listing requests inside the role's allowed S3 prefix.
    workspace_key_prefix = "networking/workspaces"
  }
}
