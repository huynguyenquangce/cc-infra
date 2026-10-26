output "github_role_arns" { value = module.github_oidc.role_arns }
output "state_bucket_name" { value = module.state_backend.bucket_name }
output "mcp_app_role_arns" { value = module.github_oidc.mcp_app_role_arns }
