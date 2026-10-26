mock_provider "aws" {
  mock_data "aws_ec2_managed_prefix_list" {
    defaults = { id = "pl-3b927c52" }
  }
}
variables {
  environment    = "uat"
  aws_account_id = "123456789012"
  aws_region     = "us-east-1"
  vpc_id         = "vpc-0123456789abcdef0"
  alb_subnet_ids = ["subnet-0123456789abcdef0", "subnet-1123456789abcdef0"]
  backend_targets = {
    first  = "172.19.16.23"
    second = "172.19.16.24"
    third  = "172.19.16.25"
    fourth = "172.19.16.26"
  }
}
run "routing_and_public_surface" {
  command = plan
  assert {
    condition     = aws_lb.this.internal && aws_lb_target_group.backend.target_type == "ip" && aws_lb_target_group.backend.protocol == "HTTP" && aws_lb_target_group.backend.port == 9010
    error_message = "The internal ALB must route to on-prem IP targets over HTTP 9010."
  }
  assert {
    condition     = aws_lb_listener.http.port == 80 && aws_lb_listener.http.default_action[0].type == "forward" && aws_vpc_security_group_ingress_rule.cloudfront.prefix_list_id == "pl-3b927c52" && aws_vpc_security_group_ingress_rule.cloudfront.cidr_ipv4 == null
    error_message = "Only CloudFront (VPC origin) may reach the HTTP listener."
  }
  assert {
    condition     = length(aws_lb_target_group_attachment.backend) == 4 && alltrue([for t in aws_lb_target_group_attachment.backend : t.port == 9010 && t.availability_zone == "all"])
    error_message = "All registered on-prem targets must use HTTP port 9010 and AZ all."
  }
  assert {
    condition     = aws_lb_target_group.backend.health_check[0].path == "/health" && aws_lb_target_group.backend.health_check[0].matcher == "200"
    error_message = "Health check must match the backend contract, not /api/health."
  }
  assert {
    condition     = aws_lb_listener_rule.block_testing.priority < aws_lb_listener_rule.block_documentation[0].priority && aws_lb_listener_rule.block_testing.action[0].fixed_response[0].status_code == "403" && length(aws_lb_listener_rule.block_documentation) == 1
    error_message = "Testing/docs blocks must sit on the listener ahead of the default forward to protect the mock API."
  }
  assert {
    condition     = alltrue([for r in aws_vpc_security_group_egress_rule.backend : r.from_port == 9010 && r.to_port == 9010 && endswith(r.cidr_ipv4, "/32")])
    error_message = "Backend egress must be limited to individual approved IPs on 9010."
  }
  assert {
    condition     = !aws_s3_bucket.logs.force_destroy && aws_lb.this.preserve_host_header
    error_message = "Preserve logs by default and preserve the customer API host header."
  }
}
run "reject_public_vpn_endpoint_as_backend" {
  command = plan
  variables { backend_targets = { wrong = "66.215.9.236" } }
  expect_failures = [var.backend_targets]
}
run "production_defaults_are_isolated" {
  command = plan
  variables { environment = "production" }
  assert {
    condition     = aws_lb.this.name == "cc-production-api-proxy" && aws_lb.this.enable_deletion_protection && aws_s3_bucket.logs.bucket == "cc-123456789012-us-east-1-production-api-proxy-logs"
    error_message = "Production must use isolated names/logs and deletion protection."
  }
}
