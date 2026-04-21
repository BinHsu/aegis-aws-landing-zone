# -----------------------------------------------------------------------------
# SSM Parameter Store SecureString encryption key — ADR-022
# -----------------------------------------------------------------------------
# Single account-level KMS key used to encrypt SecureString values under
# /aegis/staging/grafana-cloud/*. Lives in the bootstrap layer (not platform)
# because:
#
#   - Runbook 006 Part 2 requires `alias/aegis-staging-secrets` to exist
#     BEFORE the operator puts the Grafana Cloud bootstrap token (Part 2
#     happens BEFORE any observability TF apply). Baseline-layer auto-apply
#     on PR merge satisfies that prerequisite without a session-gated
#     gh workflow run.
#
#   - Tearing down and re-applying platform (session cadence) must NOT
#     rotate this key — SSM PS values encrypted with the old key would
#     become undecryptable on the new key. Bootstrap persists across
#     session teardown.
#
# Multi-region posture (ADR-022 §Multi-region): single KMS key in the
# primary region. Both EKS cluster slots' External Secrets Operator IRSA
# roles read cross-region from primary-region SSM PS via the kms:ViaService
# condition in their IAM policy. Avoids per-region KMS + SSM replication;
# trade-off is slave cluster's ESO makes cross-region API calls on refresh
# (1h default) — accepted for lab cardinality.
#
# Key policy grants kms:* to account root only. IRSA roles in the platform
# layer attach kms:Decrypt via their own IAM policies, which avoids circular
# bootstrap ↔ platform updates every time a new cluster slot lands.
# -----------------------------------------------------------------------------

resource "aws_kms_key" "secrets" {
  description             = "SSM PS SecureString encryption for /aegis/staging/grafana-cloud/* (ADR-022)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccountAdmin"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
    ]
  })

  tags = merge(local.tags, {
    Name = "aegis-staging-secrets"
  })
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/aegis-staging-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}
