# -----------------------------------------------------------------------------
# aegis-core CI roles — least-privilege, per-function
# -----------------------------------------------------------------------------
# Requested by aegis-core #72. Each role serves one CI function with the
# minimum permissions needed. The Terraform CI role (github-actions-terraform)
# in oidc-github.tf does NOT cover aegis-core — sharing Admin with the app
# repo is a supply-chain escalation risk.
#
# Two roles:
#   1. github-actions-aegis-core-ecr   — ECR push (release builds)
#   2. github-actions-aegis-core-cache — S3 Bazel remote cache (all builds)
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# 1. ECR push role — main branch only
# -----------------------------------------------------------------------------
# aegis-core CI assumes this role to push container images to ECR after
# a successful build on main. The inline policy is scoped to the single
# aegis-core ECR repository — no wildcards, no cross-repo access.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "aegis_core_ecr" {
  name = "github-actions-aegis-core-ecr"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${local.github_org}/${local.github_app_repo}:ref:refs/heads/main"
        }
      }
    }]
  })

  tags = {
    Name = "github-actions-aegis-core-ecr"
  }
}

resource "aws_iam_role_policy" "aegis_core_ecr" {
  name = "ecr-push"
  role = aws_iam_role.aegis_core_ecr.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "GetAuthToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PushToAegisCoreRepo"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
        ]
        Resource = aws_ecr_repository.aegis_core.arn
      },
      {
        # Read-after-write — required for rules_oci `oci_push` which fetches
        # the manifest post-push to verify the upload succeeded, and for any
        # downstream automation (Cosign signing, Trivy scanning, ArgoCD tag
        # watching) that needs to resolve the image it just pushed. Scoped
        # to the same single repo as the push permissions; the role still
        # cannot list, read, or modify any other repo in the account.
        # Requested by cross-repo aegis-core Phase 4a Slice 3 (see ldz #80).
        Sid    = "VerifyPushedManifest"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = aws_ecr_repository.aegis_core.arn
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# 2. S3 Bazel cache role — main branch only (write); PR read-only TBD
# -----------------------------------------------------------------------------
# aegis-core CI assumes this role for Bazel remote cache access. Write
# access is main-branch-only to prevent cache poisoning from fork PRs.
#
# Per aegis-core ADR-0014 §δ: S3 replaces BuildBuddy free tier when
# data residency or capacity requires it. Pre-provisioning the role and
# bucket costs near-zero and avoids a future cross-repo round-trip.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "aegis_core_cache" {
  name = "github-actions-aegis-core-cache"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${local.github_org}/${local.github_app_repo}:ref:refs/heads/main"
        }
      }
    }]
  })

  tags = {
    Name = "github-actions-aegis-core-cache"
  }
}

resource "aws_iam_role_policy" "aegis_core_cache" {
  name = "s3-bazel-cache"
  role = aws_iam_role.aegis_core_cache.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CacheBucketAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = "${aws_s3_bucket.bazel_cache.arn}/*"
      },
      {
        Sid      = "CacheBucketList"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.bazel_cache.arn
      },
    ]
  })
}
