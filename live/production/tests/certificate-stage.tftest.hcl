mock_provider "aws" {
  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "{\"version\":2,\"vpc_id\":\"vpc-0123456789abcdef0\",\"public_subnet_ids_by_environment\":{\"uat\":{\"a\":\"subnet-0123456789abcdef0\",\"b\":\"subnet-1123456789abcdef0\"},\"production\":{\"a\":\"subnet-2123456789abcdef0\",\"b\":\"subnet-3123456789abcdef0\"}}}"
    }
  }
}
variables {
  aws_account_id = "123456789012"
  domain_name    = "api-production.example.com"
}
run "certificate_only_before_external_dns" {
  command = plan
  assert {
    condition     = length(aws_acm_certificate.api) == 1 && length(aws_acm_certificate_validation.api) == 0 && length(module.api_proxy) == 0 && length(data.aws_ssm_parameter.network_contract) == 0
    error_message = "Stage 1 must request ACM without waiting for customer DNS or provisioning ALB."
  }
  assert {
    condition     = length(output.api_proxy) == 0
    error_message = "Certificate-only output must be an empty object, not an omitted null output."
  }

}

run "enabled_environment_reads_only_its_public_subnets" {
  command = plan
  variables {
    enable_alb               = true
    existing_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/01234567-89ab-cdef-0123-456789abcdef"
    backend_targets          = { first = "172.19.16.23", second = "172.19.16.24" }
    alert_emails             = ["ops@example.com"]
  }
  assert {
    condition     = length(module.api_proxy) == 1 && length(local.public_subnet_ids) == 2 && contains(local.public_subnet_ids, "subnet-2123456789abcdef0") && contains(local.public_subnet_ids, "subnet-3123456789abcdef0")
    error_message = "The production root must choose only its own subnet IDs from the shared contract."
  }
}
