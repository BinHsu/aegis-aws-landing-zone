# -----------------------------------------------------------------------------
# Customer-Managed KMS Key for Terraform State Bucket
# -----------------------------------------------------------------------------
# Replaces the default aws/s3 AWS-managed key for bucket encryption.
#
# WHY: The default aws/s3 key is account-scoped — its key policy only allows
# the owning account (shared) to use it. This blocks cross-account state
# reads via `terraform_remote_state` — which a downstream consumer in a
# workload account needs in order to read this repo's outputs, e.g. the
# org-wide IPAM pool IDs from shared/ipam.
#
# A customer-managed KMS key lets us write an explicit policy that grants
# kms:Decrypt and kms:GenerateDataKey to the landing-zone accounts' CI roles,
# gated by the aws:PrincipalOrgID condition. This is the production pattern.
#
# Key-grant scoping (#315): the CI (`gh-tf-*`) grant is enumerated per account
# — one `arn:aws:iam::<account-id>:role/gh-tf-*` entry per landing-zone account
# — instead of the former `arn:aws:iam::*:role/gh-tf-*` cross-account wildcard.
# This mirrors the S3 bucket policy's account allow-list (#314/#322): a CI role
# in any other org account (present or future) can no longer use the state key.
#
# Why the grant is NOT scoped to each account's own state PREFIX (the way the
# S3 object policy is): this is ONE bucket-encryption key and the bucket has S3
# Bucket Keys enabled (`bucket_key_enabled = true` in main.tf). With Bucket Keys
# on, S3 sets the KMS encryption context to the BUCKET ARN, not the per-object
# ARN, so a `kms:EncryptionContext:aws:s3:arn` condition cannot distinguish one
# account's prefix from another's — every account's state is sealed under the
# same key with the same (bucket-scoped) context. Per-object-prefix CRYPTO
# isolation therefore is not expressible at this key while Bucket Keys are on;
# that confidentiality boundary is enforced at the S3 object-policy layer
# (#314/#322), and this KMS scope-down is defense-in-depth that shrinks the
# principal set. True per-account crypto isolation would require a SEPARATE KMS
# key per account (an ADR-scale change) — see PR body "open questions".
# Ref: docs.aws.amazon.com/AmazonS3/latest/userguide/UsingKMSEncryption.html
# (encryption-context section — bucket ARN under S3 Bucket Keys).
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
        Sid       = "AllowAllowListedPrincipalsDecryptAndEncrypt"
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
          ArnLike = {
            # #315: per-account CI role enumeration replaces the former
            # `arn:aws:iam::*:role/gh-tf-*` cross-account wildcard. Built from
            # the same account map the S3 bucket policy uses (local.ci_state_
            # accounts), so the KMS grant tracks the S3 allow-list exactly.
            "aws:PrincipalArn" = concat(
              [for name, id in local.ci_state_accounts : "arn:aws:iam::${id}:role/gh-tf-*"],
              [
                # Break-glass + SSO PlatformAdmin stay account-wildcarded by
                # design — cross-account incident-response / human-operator
                # identities, matching main.tf's AllowBreakGlassAndAdminAllState.
                "arn:aws:iam::*:role/aegis-emergency-*",
                "arn:aws:iam::*:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_PlatformAdmin_*",
              ],
            )
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
