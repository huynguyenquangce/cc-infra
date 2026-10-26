# Shared image registry: one immutable image is built once and promoted from UAT to Production.
resource "aws_ecr_repository" "this" {
  name                 = var.name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}
# Expire untagged layers quickly and keep a bounded history of tagged images for rollback.
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1, description = "Expire untagged images after 7 days"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2, description = "Keep the most recent tagged images"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = var.max_image_count }
        action       = { type = "expire" }
      }
    ]
  })
}
