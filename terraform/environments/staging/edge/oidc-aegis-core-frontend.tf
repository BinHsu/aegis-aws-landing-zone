# -----------------------------------------------------------------------------
# aegis-core CI role — frontend deploy (S3 sync + CloudFront invalidation)
# -----------------------------------------------------------------------------
# Cross-repo role for aegis-core's `release-staging-frontend.yml` workflow.
# Shape mirrors the existing ECR push role (terraform/environments/staging/
# bootstrap/oidc-aegis-core.tf) — same OIDC provider, same sub-claim pattern,
# role-per-function.
#
# Trust scope (three conditions for depth-in-defense):
#   1. sub = repo:BinHsu/aegis-core:ref:refs/heads/main
#   2. job_workflow_ref pinned to the specific workflow file path
#   3. aud = sts.amazonaws.com
#
# Policy:
#   - s3:PutObject / s3:DeleteObject on the frontend bucket
#   - s3:ListBucket on the frontend bucket (required for `aws s3 sync`)
#   - cloudfront:CreateInvalidation on the specific distribution
#
# NO:
#   - No s3: actions on any other bucket
#   - No cloudfront:GetDistribution (workflow parameterizes dist ID via GH
#     Actions secret, doesn't list)
#   - No ECR, no IAM, no anything else
# -----------------------------------------------------------------------------

# The GitHub OIDC provider is already provisioned in staging/bootstrap —
# we look it up rather than re-creating.
data "terraform_remote_state" "staging_bootstrap" {
  backend = "s3"
  config = {
    bucket = "${local.config.organization.name}-terraform-state-${local.config.accounts.shared.id}"
    key    = "staging/bootstrap/terraform.tfstate"
    region = local.primary_region
  }
}

locals {
  github_oidc_provider_arn = data.terraform_remote_state.staging_bootstrap.outputs.github_oidc_provider_arn
  aegis_core_repo          = "${local.config.github.org}/${local.config.github.app_repo}"
}

resource "aws_iam_role" "aegis_core_frontend" {
  name = "github-actions-aegis-core-frontend"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = local.github_oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud"              = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:job_workflow_ref" = "${local.aegis_core_repo}/.github/workflows/release-staging-frontend.yml@refs/heads/main"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${local.aegis_core_repo}:ref:refs/heads/main"
        }
      }
    }]
  })

  tags = {
    Name = "github-actions-aegis-core-frontend"
  }
}

resource "aws_iam_role_policy" "aegis_core_frontend" {
  name = "frontend-deploy"
  role = aws_iam_role.aegis_core_frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3WriteToFrontendBucket"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = "${aws_s3_bucket.frontend.arn}/*"
      },
      {
        Sid      = "S3ListFrontendBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.frontend.arn
      },
      {
        Sid      = "CloudFrontInvalidation"
        Effect   = "Allow"
        Action   = "cloudfront:CreateInvalidation"
        Resource = aws_cloudfront_distribution.frontend.arn
      },
    ]
  })
}
