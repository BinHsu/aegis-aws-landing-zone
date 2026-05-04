# -----------------------------------------------------------------------------
# Shared Account Bootstrap — Terraform State Bucket
# -----------------------------------------------------------------------------
# This is the Terraservices "bootstrap" layer for the shared account.
# It creates the S3 bucket that holds ALL Terraform state for the entire
# landing zone (all accounts, all layers). See ADR-003.
#
# This bucket is the single most critical piece of infrastructure in the
# project. Losing it means losing all Terraform state.
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "terraform_state" {
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.terraform_state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    # Clean up failed multipart uploads after 7 days (CKV_AWS_300)
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAllowListedPrincipals"
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = [
          aws_s3_bucket.terraform_state.arn,
          "${aws_s3_bucket.terraform_state.arn}/*",
        ]
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = local.org_id
          }
          ArnLike = {
            "aws:PrincipalArn" = [
              "arn:aws:iam::*:role/gh-tf-*",
              "arn:aws:iam::*:role/aegis-emergency-*",
              "arn:aws:iam::*:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_PlatformAdmin_*",
            ]
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.terraform_state.arn,
          "${aws_s3_bucket.terraform_state.arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
    ]
  })
}

resource "aws_iam_account_alias" "this" {
  account_alias = "binhsu-aegis-shared"
}

data "aws_caller_identity" "current" {}

check "config_account_id_not_empty" {
  assert {
    condition     = local.account_id != ""
    error_message = "accounts.shared.id in landing-zone.yaml is empty. Create the account first (Runbook 001 Part 8)."
  }
}
