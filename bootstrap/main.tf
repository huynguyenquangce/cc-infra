module "state_backend" {
  source      = "../modules/state-backend"
  bucket_name = var.state_bucket_name
}
module "github_oidc" {
  source                = "../modules/github-oidc"
  repository            = var.github_repository
  existing_provider_arn = var.existing_github_oidc_provider_arn
  state_bucket_arn      = module.state_backend.bucket_arn
  aws_region            = var.aws_region
  aws_account_id        = var.aws_account_id
}
