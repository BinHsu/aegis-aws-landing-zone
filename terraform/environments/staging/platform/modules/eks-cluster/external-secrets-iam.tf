# -----------------------------------------------------------------------------
# External Secrets Operator — IRSA (ADR-022 §IAM policy)
# -----------------------------------------------------------------------------
# One IRSA role per cluster slot. Trust policy binds to the
# external-secrets:external-secrets ServiceAccount created by the ESO chart.
# Permission policy is scoped to the /aegis/staging/grafana-cloud/* SSM PS
# path in the PRIMARY region — both primary and slave cluster ESO instances
# read cross-region from the single primary-region SSM PS (per ADR-022
# §Multi-region). Slave clusters therefore hit primary-region SSM + KMS
# APIs on each refresh; acceptable at 1h default cadence + lab cardinality.
#
# The KMS statement uses `kms:ViaService = ssm.<primary_region>.amazonaws.com`
# so ESO cannot use kms:Decrypt via any path except SSM — a direct kms:Decrypt
# on a ciphertext blob retrieved by other means would fail the condition.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "external_secrets" {
  count = var.observability_enabled ? 1 : 0

  provider = aws.this

  name = "${var.cluster_name}-external-secrets"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.cluster.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_host}:sub" = "system:serviceaccount:external-secrets:external-secrets"
        }
      }
    }]
  })

  tags = merge(var.tags, {
    Name       = "${var.cluster_name}-external-secrets"
    RegionRole = var.region_key
  })
}

resource "aws_iam_role_policy" "external_secrets" {
  count = var.observability_enabled ? 1 : 0

  provider = aws.this

  name = "${var.cluster_name}-external-secrets"
  role = aws_iam_role.external_secrets[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadGrafanaCloudSSMParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
        ]
        Resource = [
          "arn:aws:ssm:${var.primary_region}:${var.account_id}:parameter/aegis/staging/grafana-cloud/*",
        ]
      },
      {
        Sid      = "DecryptGrafanaCloudSSMParameters"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = var.secrets_kms_key_arn
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${var.primary_region}.amazonaws.com"
          }
        }
      },
    ]
  })
}
