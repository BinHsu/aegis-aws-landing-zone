# -----------------------------------------------------------------------------
# Customer-Managed KMS Key for Terraform State Bucket
# -----------------------------------------------------------------------------
# Replaces the default aws/s3 AWS-managed key for bucket encryption.
#
# WHY: The default aws/s3 key is account-scoped — its key policy only allows
# the owning account (shared) to use it. This blocks cross-account state
# reads via `terraform_remote_state`, which Phase 3+ requires heavily
# (staging/network reads shared/ipam, etc.).
#
# A customer-managed KMS key lets us write an explicit policy that grants
# kms:Decrypt and kms:GenerateDataKey to any principal in the organization
# via the aws:PrincipalOrgID condition. This is the production pattern.
#
# Cost: $1/month per CMK + $0.03 per 10,000 requests. For lab scale,
# well under $2/month even with heavy Terraform activity.
# -----------------------------------------------------------------------------

resource "aws_kms_key" "terraform_state" {
  description             = "Aegis Terraform state bucket — cross-account encryption key"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccountPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowOrganizationDecryptAndEncrypt"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = local.org_id
          }
        }
      },
    ]
  })
}

resource "aws_kms_alias" "terraform_state" {
  name          = "alias/aegis-terraform-state"
  target_key_id = aws_kms_key.terraform_state.id
}
