# Public HTTPS edge for an internal ALB without a custom domain.
# CloudFront serves *.cloudfront.net with its default certificate and reaches the ALB privately through a VPC origin.
locals {
  # AWS managed CloudFront policies (fixed IDs): no caching, forward every viewer header except Host.
  caching_disabled_policy_id       = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
  all_viewer_except_host_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
}
# CloudFront-managed ENIs in the ALB subnets; traffic to the ALB stays on the AWS network.
resource "aws_cloudfront_vpc_origin" "this" {
  vpc_origin_endpoint_config {
    name                   = var.name
    arn                    = var.alb_arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"
    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}
# HTTPS-only distribution; every method and header (Authorization included) reaches the origin uncached.
resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  comment         = var.comment
  price_class     = var.price_class
  http_version    = "http2"
  is_ipv6_enabled = true
  origin {
    origin_id   = "alb"
    domain_name = var.alb_dns_name
    vpc_origin_config {
      vpc_origin_id            = aws_cloudfront_vpc_origin.this.id
      origin_read_timeout      = var.origin_read_timeout_seconds
      origin_keepalive_timeout = 5
    }
  }
  default_cache_behavior {
    target_origin_id         = "alb"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = local.caching_disabled_policy_id
    origin_request_policy_id = local.all_viewer_except_host_policy_id
    compress                 = false
  }
  restrictions {
    geo_restriction { restriction_type = "none" }
  }
  viewer_certificate { cloudfront_default_certificate = true }
}
