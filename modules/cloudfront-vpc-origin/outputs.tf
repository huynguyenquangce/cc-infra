output "domain_name" { value = aws_cloudfront_distribution.this.domain_name }
output "endpoint" { value = "https://${aws_cloudfront_distribution.this.domain_name}" }
output "distribution_id" { value = aws_cloudfront_distribution.this.id }
output "vpc_origin_id" { value = aws_cloudfront_vpc_origin.this.id }
