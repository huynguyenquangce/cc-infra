terraform {
  backend "s3" {
    workspace_key_prefix = "production/workspaces"
  }
}
