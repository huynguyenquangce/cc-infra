output "role_arns" { value = { for k, v in aws_iam_role.terraform : k => v.arn } }
output "mcp_app_role_arns" { value = { for k, v in aws_iam_role.mcp_app : k => v.arn } }
