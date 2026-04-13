# -----------------------------------------------------------------------------
# ECR Repositories — staging account per ADR-013
# -----------------------------------------------------------------------------
# Container images for workloads running in this account. ADR-013 explicitly
# chose ECR over Docker Hub to avoid anonymous-pull rate limits that
# Karpenter-driven scaling can hit trivially.
#
# Phase 3b preparation: create the aegis-core repository before the EKS
# platform exists, so CI builds from the companion repo can push images
# immediately when Phase 3c lands.
#
# Encryption: KMS with the AWS-managed aws/ecr key. Free (AWS-managed keys
# have no charge), scoped to this account (sufficient for workload image
# scope — no cross-account sharing planned).
#
# Image tag policy: IMMUTABLE. Prevents accidental overwrite of a deployed
# image's tag, which is a known cause of "it worked yesterday" incidents.
#
# Lifecycle: keep the 10 most recent images per repo. Older images expire
# automatically. $0.10/GB/month storage rounds to pennies at this retention.
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "aegis_core" {
  name                 = "aegis-core"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    # kms_key unspecified → uses AWS-managed aws/ecr (free)
  }
}

resource "aws_ecr_lifecycle_policy" "aegis_core" {
  repository = aws_ecr_repository.aegis_core.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the 10 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
