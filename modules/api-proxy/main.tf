locals {
  name            = "cc-${var.environment}-api-proxy"
  log_bucket_name = "cc-${var.aws_account_id}-${var.aws_region}-${var.environment}-api-proxy-logs"
}
# Public ALB: accept HTTPS, preserve the Host header, and write access logs to S3.
resource "aws_lb" "this" {
  name                       = local.name
  internal                   = false
  load_balancer_type         = "application"
  ip_address_type            = "ipv4"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.public_subnet_ids
  enable_deletion_protection = var.enable_deletion_protection
  idle_timeout               = var.idle_timeout_seconds
  preserve_host_header       = true
  drop_invalid_header_fields = true
  access_logs {
    bucket  = aws_s3_bucket.logs.id
    prefix  = "access"
    enabled = true
  }
  depends_on = [aws_s3_bucket_policy.logs, aws_s3_bucket_server_side_encryption_configuration.logs, aws_s3_bucket_public_access_block.logs, aws_s3_bucket_ownership_controls.logs]
}

# Security groups: accept client HTTPS and allow only approved backends on port 9010.
# Dedicated security group for this environment's ALB.
resource "aws_security_group" "alb" {
  name        = local.name
  description = "Public HTTPS listener; HTTP backend traffic only to approved Commerce targets"
  vpc_id      = var.vpc_id
}
# Allow configured client CIDRs to access HTTPS on port 443.
resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each          = var.allowed_client_cidrs
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}
# Allow HTTP on port 80 for the HTTPS redirect listener.
resource "aws_vpc_security_group_ingress_rule" "http_redirect" {
  for_each          = var.enable_http_redirect ? var.allowed_client_cidrs : toset([])
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}
# Restrict ALB egress to individual private backend IPs on TCP port 9010.
resource "aws_vpc_security_group_egress_rule" "backend" {
  for_each          = var.backend_targets
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "${each.value}/32"
  ip_protocol       = "tcp"
  from_port         = 9010
  to_port           = 9010
  description       = "Commerce ${each.key}: HTTP and health checks over VPN"
}

# Backends over VPN: private IP registration, HTTP port 9010, and health checks.
# HTTP target group on port 9010 with IP targets and endpoint health checks.
resource "aws_lb_target_group" "backend" {
  name                 = local.name
  vpc_id               = var.vpc_id
  target_type          = "ip"
  protocol             = "HTTP"
  port                 = 9010
  deregistration_delay = 30
  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = "traffic-port"
    path                = var.health_check_path
    matcher             = "200"
    interval            = var.health_check_interval_seconds
    timeout             = var.health_check_timeout_seconds
    healthy_threshold   = var.healthy_threshold
    unhealthy_threshold = var.unhealthy_threshold
  }
}
# Register each customer backend IP and make it available to ALB nodes in both AZs.
resource "aws_lb_target_group_attachment" "backend" {
  for_each          = var.backend_targets
  target_group_arn  = aws_lb_target_group.backend.arn
  target_id         = each.value
  port              = 9010
  availability_zone = "all"
}

# Listeners and routing: HTTPS, test/docs endpoint blocks, and HTTP-to-HTTPS redirects.
# HTTPS listener on port 443 using ACM; unmatched Host headers receive a 404 response.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      status_code  = "404"
      message_body = "Not found"
    }
  }
}
# These unauthenticated mock/testing endpoints must not become public via /api/*.
# Block test endpoints before forwarding to avoid exposing test tooling publicly.
resource "aws_lb_listener_rule" "block_testing" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10
  condition {
    path_pattern { values = ["/api/test", "/api/test/*"] }
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
# Block Swagger, Redoc, and OpenAPI on the public ALB when configured.
resource "aws_lb_listener_rule" "block_documentation" {
  count        = var.block_documentation ? 1 : 0
  listener_arn = aws_lb_listener.https.arn
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
# Forward requests to the backend only when the Host matches the API domain.
resource "aws_lb_listener_rule" "forward" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100
  condition {
    host_header { values = [var.domain_name] }
  }
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}
# HTTP listener on port 80 redirects clients to HTTPS on port 443.
resource "aws_lb_listener" "http" {
  count             = var.enable_http_redirect ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Access logs: dedicated S3 bucket, encryption, delivery policy, and retention.
# Dedicated access log bucket for this environment; force deletion is disabled by default.
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

# Monitoring: SNS notifications, CloudWatch alarms, and a dashboard.
# Dedicated SNS topic for this environment's CloudWatch alarms.
resource "aws_sns_topic" "alerts" { name = "${local.name}-alerts" }
# CloudWatch publishes as a service principal, independently of the Terraform role.
# Allow CloudWatch publishing only from this account and environment's alarm prefix.
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
  alarm_actions = concat([aws_sns_topic.alerts.arn], var.additional_alarm_action_arns)
  count_alarms = {
    healthy-targets          = { metric = "HealthyHostCount", statistic = "Minimum", comparison = "LessThanThreshold", threshold = var.minimum_healthy_targets, group = true, missing = "breaching" }
    alb-5xx                  = { metric = "HTTPCode_ELB_5XX_Count", statistic = "Sum", comparison = "GreaterThanOrEqualToThreshold", threshold = var.error_count_threshold, group = false, missing = "notBreaching" }
    backend-5xx              = { metric = "HTTPCode_Target_5XX_Count", statistic = "Sum", comparison = "GreaterThanOrEqualToThreshold", threshold = var.error_count_threshold, group = true, missing = "notBreaching" }
    target-connection-errors = { metric = "TargetConnectionErrorCount", statistic = "Sum", comparison = "GreaterThanOrEqualToThreshold", threshold = var.error_count_threshold, group = false, missing = "notBreaching" }
  }
  alb_dimension     = { LoadBalancer = aws_lb.this.arn_suffix }
  target_dimensions = merge(local.alb_dimension, { TargetGroup = aws_lb_target_group.backend.arn_suffix })
}
# Monitor healthy target count, ALB/backend errors, and backend connection errors.
resource "aws_cloudwatch_metric_alarm" "counts" {
  depends_on          = [aws_sns_topic_policy.alerts]
  for_each            = local.count_alarms
  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = "${var.environment} API Proxy: ${each.value.metric}; inspect ALB target health and shared VPN."
  namespace           = "AWS/ApplicationELB"
  metric_name         = each.value.metric
  statistic           = each.value.statistic
  comparison_operator = each.value.comparison
  threshold           = each.value.threshold
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  treat_missing_data  = each.value.missing
  dimensions          = each.value.group ? local.target_dimensions : local.alb_dimension
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
# Alert when backend p95 latency exceeds the configured threshold.
resource "aws_cloudwatch_metric_alarm" "latency" {
  depends_on                            = [aws_sns_topic_policy.alerts]
  alarm_name                            = "${local.name}-latency-p95"
  namespace                             = "AWS/ApplicationELB"
  metric_name                           = "TargetResponseTime"
  extended_statistic                    = "p95"
  comparison_operator                   = "GreaterThanThreshold"
  threshold                             = var.latency_p95_seconds
  period                                = 60
  evaluation_periods                    = 3
  datapoints_to_alarm                   = 2
  evaluate_low_sample_count_percentiles = "ignore"
  treat_missing_data                    = "notBreaching"
  dimensions                            = local.target_dimensions
  alarm_actions                         = local.alarm_actions
  ok_actions                            = local.alarm_actions
}
# Alert when the ACM certificate approaches expiration.
resource "aws_cloudwatch_metric_alarm" "certificate_expiry" {
  depends_on          = [aws_sns_topic_policy.alerts]
  alarm_name          = "${local.name}-certificate-expiry"
  namespace           = "AWS/CertificateManager"
  metric_name         = "DaysToExpiry"
  statistic           = "Minimum"
  dimensions          = { CertificateArn = var.certificate_arn }
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 30
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
# Dashboard for this environment's traffic, target health, errors, and latency.
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = local.name
  dashboard_body = jsonencode({ widgets = [
    for index, widget in [
      { title = "Request volume", metrics = [["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.this.arn_suffix, { stat = "Sum" }]] },
      { title = "Target health", metrics = [["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", aws_lb.this.arn_suffix, "TargetGroup", aws_lb_target_group.backend.arn_suffix, { stat = "Minimum" }], ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", aws_lb.this.arn_suffix, "TargetGroup", aws_lb_target_group.backend.arn_suffix, { stat = "Maximum" }]] },
      { title = "ALB and backend 5xx", metrics = [["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", aws_lb.this.arn_suffix, { stat = "Sum" }], ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.this.arn_suffix, "TargetGroup", aws_lb_target_group.backend.arn_suffix, { stat = "Sum" }]] },
      { title = "Backend latency p95", metrics = [["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.this.arn_suffix, "TargetGroup", aws_lb_target_group.backend.arn_suffix, { stat = "p95" }]] },
      { title = "Backend connection errors", metrics = [["AWS/ApplicationELB", "TargetConnectionErrorCount", "LoadBalancer", aws_lb.this.arn_suffix, { stat = "Sum" }]] }
      ] : {
      type       = "metric", x = (index % 2) * 12, y = floor(index / 2) * 6, width = 12, height = 6
      properties = { title = "${var.environment}: ${widget.title}", region = var.aws_region, period = 60, view = "timeSeries", metrics = widget.metrics }
    }
  ] })
}
