mock_provider "aws" {}
variables {
  name         = "cc-uat-api-proxy"
  comment      = "cc-uat-api-proxy: test"
  alb_arn      = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/cc-uat-api-proxy/0123456789abcdef"
  alb_dns_name = "internal-cc-uat-api-proxy-123.us-east-1.elb.amazonaws.com"
}
run "https_only_default_certificate_no_cache" {
  command = plan
  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].viewer_protocol_policy == "https-only" && aws_cloudfront_distribution.this.viewer_certificate[0].cloudfront_default_certificate
    error_message = "Viewers must use HTTPS on the default *.cloudfront.net certificate."
  }
  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].cache_policy_id == "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" && contains(aws_cloudfront_distribution.this.default_cache_behavior[0].allowed_methods, "POST")
    error_message = "API traffic must be uncached and allow every method."
  }
  assert {
    condition     = aws_cloudfront_vpc_origin.this.vpc_origin_endpoint_config[0].origin_protocol_policy == "http-only" && aws_cloudfront_vpc_origin.this.vpc_origin_endpoint_config[0].arn == var.alb_arn
    error_message = "The VPC origin must target the internal ALB over HTTP inside the VPC."
  }
}
run "reject_origin_timeout_above_quota" {
  command = plan
  variables { origin_read_timeout_seconds = 120 }
  expect_failures = [var.origin_read_timeout_seconds]
}
