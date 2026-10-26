output "endpoint" {
  description = "Public HTTPS base URL; MCP servers are at <endpoint>/mcp/<name>, Squirrel webhooks at <endpoint>/webhooks/squirrel/..."
  value       = module.cloudfront.endpoint
}
output "cloudfront_distribution_id" { value = module.cloudfront.distribution_id }
output "alb_dns_name" { value = aws_lb.this.dns_name }
output "alb_arn" { value = aws_lb.this.arn }
output "target_group_arn" { value = aws_lb_target_group.this.arn }
output "cluster_name" { value = aws_ecs_cluster.this.name }
output "service_name" { value = local.name }
output "task_family" { value = aws_ecs_task_definition.this.family }
output "container_name" { value = local.container_name }
output "image_parameter_name" { value = aws_ssm_parameter.image.name }
output "secret_names" { value = { for k, s in aws_secretsmanager_secret.vendor : k => s.name } }
output "execution_role_arn" { value = aws_iam_role.execution.arn }
output "task_role_arn" { value = aws_iam_role.task.arn }
output "service_security_group_id" { value = aws_security_group.service.id }
output "log_group_name" { value = aws_cloudwatch_log_group.this.name }
output "log_bucket_name" { value = aws_s3_bucket.logs.id }
output "sns_topic_arn" { value = aws_sns_topic.alerts.arn }
