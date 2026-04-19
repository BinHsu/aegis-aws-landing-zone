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

# -----------------------------------------------------------------------------
# Repository policy — Deny push from any principal except the OIDC role
# -----------------------------------------------------------------------------
# Server-side defense-in-depth for aegis-core's image push pipeline, paired
# with the Bazel-side `target_compatible_with = ["@platforms//os:linux"]`
# gate on `oci_push` rules. Asked for in cross-repo issue #83.
#
# Attack surfaces this closes:
#   - A dev with AWS console / CLI access running `docker push` manually
#     from a macOS box — previously would have uploaded a Mach-O-inside-
#     Linux-image that confuses downstream consumers (ArgoCD, Cosign,
#     Trivy). Now rejected by ECR with AccessDenied before any bytes land.
#   - A future contributor with AWS access who skips reading CLAUDE.md
#     and tries direct `docker push`. Same rejection.
#
# What this does NOT catch:
#   - A compromised CI runner that has the OIDC token. At that point we
#     have larger problems than a bad image in ECR.
#
# The OIDC role principal is the single exception. Cosign signing (future
# Phase 4b) will use the same role; if a second push identity arrives, add
# a second ArnEquals entry to the condition — do not weaken to a prefix
# match.
# -----------------------------------------------------------------------------

resource "aws_ecr_repository_policy" "aegis_core_push_restriction" {
  repository = aws_ecr_repository.aegis_core.name

  # ECR repository-policy quirks addressed here vs. the first attempt that
  # failed apply with `Invalid repository policy provided` (baseline run
  # 24629024427):
  #   1. Principal uses the nested `{ AWS = "*" }` form. ECR rejects the
  #      string-shorthand `Principal = "*"` in repository policies even
  #      though IAM identity policies accept it.
  #   2. `Resource` field omitted. For repository policies, the resource
  #      is inherent (the repo itself); including an explicit `"*"` made
  #      ECR interpret it as a malformed cross-resource policy.
  #   3. `BatchCheckLayerAvailability` removed from the deny list. It is
  #      called on the pull path as well as the push path — denying it
  #      for non-OIDC principals would break pulls from Karpenter nodes,
  #      ArgoCD, and any future Cosign/Trivy consumer. The four remaining
  #      actions (PutImage + the three LayerUpload primitives) are
  #      push-only and sufficient to block `docker push`.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyPushExceptFromOIDCRole"
      Effect = "Deny"
      Principal = {
        AWS = "*"
      }
      Action = [
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
      ]
      Condition = {
        StringNotEquals = {
          "aws:PrincipalArn" = aws_iam_role.aegis_core_ecr.arn
        }
      }
    }]
  })
}
