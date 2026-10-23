output "role_arns" { value = { for k, v in aws_iam_role.terraform : k => v.arn } }
