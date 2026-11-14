resource "aws_ecr_repository" "api" {
  name                 = "mini-crm-api"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Project = "MiniCRM"
  }
}
