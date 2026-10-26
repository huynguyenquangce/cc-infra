locals {
  name            = "cc-${var.environment}-mcp"
  container_name  = "mcp-server"
  container_port  = 8000
  log_bucket_name = "cc-${var.aws_account_id}-${var.aws_region}-${var.environment}-mcp-logs"
  log_group_name  = "/ecs/mcp-server/${var.environment}"
  # Secret JSON keys per vendor -> container variable names read by the application settings classes.
  vendor_secret_keys = {
    squirrel = { SQUIRREL_CLIENT_ID = "client_id", SQUIRREL_CLIENT_SECRET = "client_secret", SQUIRREL_WEBHOOK_SECRET = "webhook_secret" }
    genesis  = { GENESIS_API_PASS = "api_pass", GENESIS_CASINO_ID = "casino_id" }
  }
  container_environment = merge(var.app_environment, { COMMERCE_ENABLED_FEATURES = join(",", var.enabled_features) })
  container_secrets = flatten([for vendor in var.enabled_features : [
    for variable, key in local.vendor_secret_keys[vendor] : { name = variable, valueFrom = "${aws_secretsmanager_secret.vendor[vendor].arn}:${key}::" }
  ]])
}

# Configuration owned outside Terraform: vendor secret values and the deployed image digest.
# Secret containers only; values are written with put-secret-value so they never reach Terraform state.
resource "aws_secretsmanager_secret" "vendor" {
  for_each                = local.vendor_secret_keys
  name                    = "cc-mcp/${var.environment}/${each.key}"
  description             = "MCP ${each.key} credentials for ${var.environment}. JSON keys: ${join(", ", values(each.value))}. Set outside Terraform."
  recovery_window_in_days = var.secret_recovery_window_days
}
# Deployed image digest. Terraform seeds it once; the application CI overwrites it on every release.
resource "aws_ssm_parameter" "image" {
  name        = "/cc/${var.environment}/mcp/image"
  description = "ECR image (by digest) currently deployed for the ${var.environment} MCP service."
  type        = "String"
  value       = var.initial_image
  lifecycle { ignore_changes = [value] }
}

# Task identity: pull the image, write logs, and read only this environment's vendor secrets.
# Execution role used by the ECS agent before the container starts.
resource "aws_iam_role" "execution" {
  name = "${local.name}-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = var.aws_account_id } }
    }]
  })
}
# Least-privilege pull, log, and secret access for the execution role.
resource "aws_iam_role_policy" "execution" {
  role = aws_iam_role.execution.id
  name = "pull-image-logs-secrets"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      {
        Effect   = "Allow", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
        Resource = "arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/${var.ecr_repository_name}"
      },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.this.arn}:*" },
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [for s in aws_secretsmanager_secret.vendor : s.arn] }
    ]
  })
}
# Application role; the MCP host calls no AWS APIs, so it has no permissions.
resource "aws_iam_role" "task" {
  name = "${local.name}-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = var.aws_account_id } }
    }]
  })
}
# Container stdout/stderr, one log group per environment.
resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
}

# Security groups: CloudFront -> ALB :80 -> tasks :8000; task egress only to endpoints, vendors, and VPN targets.
# CloudFront origin-facing addresses, used by the VPC origin to reach the internal ALB.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}
# Dedicated ALB group: the CloudFront prefix list consumes most of the per-group rule quota.
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Internal MCP ALB: HTTP only from CloudFront VPC origin"
  vpc_id      = var.vpc_id
}
# Allow CloudFront (via the VPC origin) to reach the HTTP listener.
resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}
# Forward and health-check traffic from the ALB to tasks only.
resource "aws_vpc_security_group_egress_rule" "alb_to_service" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.service.id
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
}
# Task group: no inbound except from the ALB and no default allow-all egress.
resource "aws_security_group" "service" {
  name        = "${local.name}-service"
  description = "MCP tasks: inbound from ALB; egress to endpoints, vendors, and VPN targets"
  vpc_id      = var.vpc_id
}
# Accept container traffic from the ALB only.
resource "aws_vpc_security_group_ingress_rule" "service_from_alb" {
  security_group_id            = aws_security_group.service.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
}
# Reach ECR, CloudWatch Logs, and Secrets Manager through the interface endpoints.
resource "aws_vpc_security_group_egress_rule" "service_to_endpoints" {
  security_group_id            = aws_security_group.service.id
  referenced_security_group_id = var.endpoint_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
# Download ECR image layers from S3 through the gateway endpoint.
resource "aws_vpc_security_group_egress_rule" "service_to_s3" {
  security_group_id = aws_security_group.service.id
  prefix_list_id    = var.s3_prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}
# Vendor APIs on the internet (via NAT), e.g. Squirrel.
resource "aws_vpc_security_group_egress_rule" "service_to_vendors" {
  for_each          = var.vendor_egress_cidrs
  security_group_id = aws_security_group.service.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}
# Commerce systems over the Site-to-Site VPN, e.g. Genesis GGAPI.
resource "aws_vpc_security_group_egress_rule" "service_to_vpn" {
  for_each          = var.vpn_egress_targets
  security_group_id = aws_security_group.service.id
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  description       = "Commerce ${each.key} over VPN"
}

# Internal ALB: reachable only through CloudFront; HTTP inside the VPC, TLS terminates at CloudFront.
resource "aws_lb" "this" {
  name                       = local.name
  internal                   = true
  load_balancer_type         = "application"
  ip_address_type            = "ipv4"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.alb_subnet_ids
  enable_deletion_protection = var.enable_deletion_protection
  drop_invalid_header_fields = true
  access_logs {
    bucket  = aws_s3_bucket.logs.id
    prefix  = "access"
    enabled = true
  }
  depends_on = [aws_s3_bucket_policy.logs, aws_s3_bucket_server_side_encryption_configuration.logs, aws_s3_bucket_public_access_block.logs, aws_s3_bucket_ownership_controls.logs]
}
# Fargate tasks register by IP; readiness gates traffic during rolling deployments.
resource "aws_lb_target_group" "this" {
  name                 = local.name
  vpc_id               = var.vpc_id
  target_type          = "ip"
  protocol             = "HTTP"
  port                 = local.container_port
  deregistration_delay = 30
  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = "traffic-port"
    path                = var.health_check_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}
# Forward everything; the Host header is the ALB DNS name because CloudFront does not pass the viewer Host.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}
# Block Swagger, Redoc, and OpenAPI from the public CloudFront endpoint when configured.
resource "aws_lb_listener_rule" "block_documentation" {
  count        = var.block_documentation ? 1 : 0
  listener_arn = aws_lb_listener.http.arn
  priority     = 20
  condition {
    path_pattern { values = ["/docs", "/docs/*", "/redoc", "/redoc/*", "/openapi.json"] }
  }
  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      status_code  = "403"
      message_body = "Forbidden"
    }
  }
}

# Public HTTPS entry: CloudFront default certificate, VPC origin to the internal ALB, caching disabled.
module "cloudfront" {
  source                      = "../cloudfront-vpc-origin"
  name                        = local.name
  comment                     = "${local.name}: MCP server (${var.environment})"
  alb_arn                     = aws_lb.this.arn
  alb_dns_name                = aws_lb.this.dns_name
  origin_read_timeout_seconds = var.origin_read_timeout_seconds
  price_class                 = var.cloudfront_price_class
}

# Compute: Fargate service with circuit-breaker rollback and CPU target tracking.
# One cluster per environment.
resource "aws_ecs_cluster" "this" {
  name = local.name
}
# Task definition rendered from Terraform settings plus the image currently recorded in SSM.
# Old revisions are kept so the application CI and circuit breaker can roll back.
resource "aws_ecs_task_definition" "this" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  skip_destroy             = true
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name         = local.container_name
    image        = nonsensitive(aws_ssm_parameter.image.value)
    essential    = true
    portMappings = [{ containerPort = local.container_port, protocol = "tcp" }]
    environment  = [for name, value in local.container_environment : { name = name, value = value }]
    secrets      = local.container_secrets
    logConfiguration = {
      logDriver = "awslogs"
      options   = { awslogs-group = aws_cloudwatch_log_group.this.name, awslogs-region = var.aws_region, awslogs-stream-prefix = "mcp" }
    }
  }])
}
# Rolling deployment: start new tasks first, wait for /readyz, then drain old ones; roll back on repeated failure.
resource "aws_ecs_service" "this" {
  count                              = var.run_service ? 1 : 0
  name                               = local.name
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.this.arn
  desired_count                      = var.min_tasks
  launch_type                        = "FARGATE"
  propagate_tags                     = "SERVICE"
  health_check_grace_period_seconds  = 60
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = var.service_subnet_ids
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = local.container_name
    container_port   = local.container_port
  }
  # Auto scaling owns the running task count after creation.
  lifecycle { ignore_changes = [desired_count] }
  depends_on = [aws_lb_listener.http, aws_iam_role_policy.execution]
}
# Scale between min_tasks and max_tasks.
resource "aws_appautoscaling_target" "this" {
  count              = var.run_service ? 1 : 0
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_tasks
  max_capacity       = var.max_tasks
}
# Keep average service CPU near the target.
resource "aws_appautoscaling_policy" "cpu" {
  count              = var.run_service ? 1 : 0
  name               = "${local.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_percent
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification { predefined_metric_type = "ECSServiceAverageCPUUtilization" }
  }
}

# Access logs: dedicated S3 bucket, encryption, delivery policy, and retention.
# Dedicated ALB access log bucket for this environment; force deletion is disabled by default.
resource "aws_s3_bucket" "logs" {
  bucket        = local.log_bucket_name
  force_destroy = var.force_destroy_logs
}
# Block public access to the bucket.
resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
# Enforce bucket ownership of objects and disable ACLs.
resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule { object_ownership = "BucketOwnerEnforced" }
}
# Enable SSE-S3 encryption for objects in the bucket.
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
# Expire access logs after the configured retention period.
resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "expire-access-logs"
    status = "Enabled"
    filter { prefix = "access/" }
    expiration { days = var.log_retention_days }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}
# Allow ELB log delivery to the account-specific prefix and require HTTPS.
resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow", Principal = { Service = "logdelivery.elasticloadbalancing.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.logs.arn}/access/AWSLogs/${var.aws_account_id}/*"
      },
      {
        Effect    = "Deny", Principal = "*", Action = "s3:*"
        Resource  = [aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}

# Monitoring: SNS notifications and CloudWatch alarms for CloudFront, ALB targets, and ECS.
# Dedicated SNS topic for this environment's MCP alarms.
resource "aws_sns_topic" "alerts" { name = "${local.name}-alerts" }
# Allow CloudWatch publishing only from this account and the MCP alarm prefix.
resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEnvironmentCloudWatchAlarms"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alerts.arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.aws_account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:cloudwatch:${var.aws_region}:${var.aws_account_id}:alarm:${local.name}-*" }
      }
    }]
  })
}
# Subscribe alert email recipients; each recipient must confirm the subscription.
resource "aws_sns_topic_subscription" "email" {
  for_each  = var.alert_emails
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}
locals {
  alarm_actions     = concat([aws_sns_topic.alerts.arn], var.additional_alarm_action_arns)
  target_dimensions = { LoadBalancer = aws_lb.this.arn_suffix, TargetGroup = aws_lb_target_group.this.arn_suffix }
  service_alarms = var.run_service ? {
    unhealthy-targets   = { namespace = "AWS/ApplicationELB", metric = "UnHealthyHostCount", statistic = "Maximum", comparison = "GreaterThanThreshold", threshold = 0, missing = "notBreaching", dimensions = local.target_dimensions }
    no-healthy-targets  = { namespace = "AWS/ApplicationELB", metric = "HealthyHostCount", statistic = "Minimum", comparison = "LessThanThreshold", threshold = 1, missing = "breaching", dimensions = local.target_dimensions }
    target-5xx          = { namespace = "AWS/ApplicationELB", metric = "HTTPCode_Target_5XX_Count", statistic = "Sum", comparison = "GreaterThanOrEqualToThreshold", threshold = var.error_count_threshold, missing = "notBreaching", dimensions = local.target_dimensions }
    cpu-high            = { namespace = "AWS/ECS", metric = "CPUUtilization", statistic = "Average", comparison = "GreaterThanThreshold", threshold = 85, missing = "notBreaching", dimensions = { ClusterName = local.name, ServiceName = local.name } }
    memory-high         = { namespace = "AWS/ECS", metric = "MemoryUtilization", statistic = "Average", comparison = "GreaterThanThreshold", threshold = 85, missing = "notBreaching", dimensions = { ClusterName = local.name, ServiceName = local.name } }
    cloudfront-5xx-rate = { namespace = "AWS/CloudFront", metric = "5xxErrorRate", statistic = "Average", comparison = "GreaterThanThreshold", threshold = 5, missing = "notBreaching", dimensions = { DistributionId = module.cloudfront.distribution_id, Region = "Global" } }
  } : {}
}
# Target health, origin errors, ECS saturation, and CloudFront error rate.
resource "aws_cloudwatch_metric_alarm" "service" {
  depends_on          = [aws_sns_topic_policy.alerts]
  for_each            = local.service_alarms
  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = "${var.environment} MCP: ${each.value.metric}; check ECS events, task logs in ${local.log_group_name}, and vendor reachability."
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = each.value.statistic
  comparison_operator = each.value.comparison
  threshold           = each.value.threshold
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  treat_missing_data  = each.value.missing
  dimensions          = each.value.dimensions
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
# Alert when p99 response time approaches the vendor timeout budget.
resource "aws_cloudwatch_metric_alarm" "latency" {
  count                                 = var.run_service ? 1 : 0
  depends_on                            = [aws_sns_topic_policy.alerts]
  alarm_name                            = "${local.name}-latency-p99"
  namespace                             = "AWS/ApplicationELB"
  metric_name                           = "TargetResponseTime"
  extended_statistic                    = "p99"
  comparison_operator                   = "GreaterThanThreshold"
  threshold                             = var.latency_p99_seconds
  period                                = 60
  evaluation_periods                    = 3
  datapoints_to_alarm                   = 2
  evaluate_low_sample_count_percentiles = "ignore"
  treat_missing_data                    = "notBreaching"
  dimensions                            = local.target_dimensions
  alarm_actions                         = local.alarm_actions
  ok_actions                            = local.alarm_actions
}
