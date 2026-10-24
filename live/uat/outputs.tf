output "certificate_arn" { value = local.certificate_arn }
output "dns_validation_records" {
  description = "Send these CNAMEs to the customer DNS administrator; keep them for ACM renewal."
  value = var.existing_certificate_arn != null ? [] : [for d in aws_acm_certificate.api[0].domain_validation_options : {
    name = d.resource_record_name, type = d.resource_record_type, value = d.resource_record_value
  }]
}
# Keep an empty object in certificate-only state so workflow output commands succeed.
output "api_proxy" { value = var.enable_alb ? one(module.api_proxy) : {} }
