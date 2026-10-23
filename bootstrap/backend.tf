# Copy to backend.tf only after the first local bootstrap apply created the bucket.
terraform {
  backend "s3" {}
}
