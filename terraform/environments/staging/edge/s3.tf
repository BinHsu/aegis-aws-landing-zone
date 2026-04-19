# -----------------------------------------------------------------------------
# S3 bucket — frontend SPA assets
# -----------------------------------------------------------------------------
# OAC-locked (Origin Access Control): CloudFront is the only principal that
# can read from this bucket. The aegis-core CI OIDC role writes via
# `s3:PutObject` (from oidc-aegis-core-frontend.tf). No one else.
#
# Versioning ON. Helps with rollback (CloudFront invalidation + redeploy
# old version from bucket).
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "frontend" {
  # checkov:skip=CKV_AWS_145: SSE-S3 (AES256) is used, not KMS. SSE-KMS adds ~$0.03/10K requests for zero security benefit on a public-CDN-fronted static asset bucket (no PII, no compliance requirement to show key custody). ADR-019 Consequences "Cost" section documents this choice.
  # checkov:skip=CKV2_AWS_61: Lifecycle rule IS configured below (aws_s3_bucket_lifecycle_configuration.frontend) — Checkov's cross-resource awareness occasionally misses it.
  # checkov:skip=CKV2_AWS_62: Event notifications not needed — CloudFront invalidation is driven by the aegis-core CI workflow directly, not by S3 bucket events.
  # checkov:skip=CKV_AWS_18: S3 access logging disabled — would add a second bucket + lifecycle for the logs, not justified for lab traffic volume. Follow-up if audit requires it.
  # checkov:skip=CKV_AWS_144: Cross-region replication not configured — lab scope, single-region residency (EU).
  bucket = "${local.config.organization.name}-staging-frontend-${local.account_id}"

  tags = {
    Name = "${local.config.organization.name}-staging-frontend"
  }
}

# -----------------------------------------------------------------------------
# Public access block — belt and suspenders alongside the bucket policy
# -----------------------------------------------------------------------------

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# Ownership — disable ACLs
# -----------------------------------------------------------------------------

resource "aws_s3_bucket_ownership_controls" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# -----------------------------------------------------------------------------
# Versioning — object versioning enabled
# -----------------------------------------------------------------------------

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  versioning_configuration {
    status = "Enabled"
  }
}

# -----------------------------------------------------------------------------
# Encryption — SSE-S3 (AES256)
# -----------------------------------------------------------------------------
# SSE-S3 is free and sufficient for static-asset workload. KMS-managed would
# add $0.03/10K requests — negligible, but unnecessary since there's no
# compliance requirement to show key custody for public web assets.
# -----------------------------------------------------------------------------

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# -----------------------------------------------------------------------------
# Lifecycle — expire non-current versions after 30 days
# -----------------------------------------------------------------------------

resource "aws_s3_bucket_lifecycle_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    # Abandoned multipart uploads (CKV_AWS_300) — 7-day cap on orphan upload
    # parts. Big upload that fails mid-way doesn't accumulate charges forever.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# -----------------------------------------------------------------------------
# Bucket policy — two statements
# -----------------------------------------------------------------------------
# 1. ALLOW CloudFront (via OAC, scoped to this specific distribution) to read.
# 2. DENY PutObject from any principal except the aegis-core frontend OIDC
#    role — mirrors the ECR #83 defense-in-depth pattern. A dev with AWS
#    console access running `aws s3 sync` from their laptop gets AccessDenied.
# -----------------------------------------------------------------------------

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontRead"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.frontend.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn
          }
        }
      },
      {
        Sid    = "DenyPutExceptFromOIDCRole"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = [
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = "${aws_s3_bucket.frontend.arn}/*"
        Condition = {
          StringNotEquals = {
            "aws:PrincipalArn" = aws_iam_role.aegis_core_frontend.arn
          }
        }
      },
    ]
  })

  depends_on = [
    aws_s3_bucket_public_access_block.frontend,
  ]
}
