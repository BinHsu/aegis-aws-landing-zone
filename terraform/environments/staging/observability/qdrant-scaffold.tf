# -----------------------------------------------------------------------------
# Qdrant Cloud scaffold — ADR-025, cross-repo ldz #141
# -----------------------------------------------------------------------------
# Two SSM PS placeholders + one ExternalSecret, mirroring the team-webhooks
# pattern (tokens.tf §team-webhooks + external-secrets.tf §team_webhooks).
# The SSM PS values are operator-managed (runbook 007 §API key rotation):
# Terraform creates the SecureString shells with a placeholder; the operator
# `put-parameter`s the real `cluster-url` and `api-key` out-of-band. The
# `lifecycle.ignore_changes = [value]` block prevents subsequent `apply`
# from clobbering the operator-supplied values back to the placeholder.
#
# Layer placement: Qdrant is a vectordb for aegis-engine, not an
# observability concern. Scaffolded here by precedent (team-webhooks
# ExternalSecret in ns `aegis` from this layer) rather than category.
# ADR-027 enumerates the triggers that would justify extracting this block
# into a new `staging/data-secrets/` layer — none fire today.
#
# Contract with aegis-core (ldz #141):
#   - K8s Secret: `qdrant-credentials` in ns `aegis`
#   - Keys: `QDRANT_URL`, `QDRANT_API_KEY` (uppercase, env-var convention)
#   - URL shape: `https://<cluster-host>:6334` (gRPC port, TLS on — the
#     engine's qdrant_client infers TLS from the scheme; bare host means
#     plaintext). See engine_cpp/src/vectordb/qdrant_client.cc:132.
# Changing names requires cross-repo coordination; do not unilaterally rename.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# SSM PS — Qdrant Cloud cluster URL (operator-filled)
# -----------------------------------------------------------------------------
# Operator fills the real gRPC endpoint via AWS CLI:
#
#   aws ssm put-parameter \
#     --region eu-central-1 \
#     --name /aegis/staging/qdrant-cloud/cluster-url \
#     --type SecureString --key-id alias/aegis-staging-secrets \
#     --value 'https://<cluster-uuid>.eu-central-1-0.aws.cloud.qdrant.io:6334' \
#     --overwrite
#
# As of 2026-04-23 the live value is already in SSM PS from the pre-Terraform
# manual bootstrap (Runbook 007). Terraform's create picks up the placeholder
# on first apply; the `lifecycle.ignore_changes` block leaves the operator
# value in place on subsequent applies.
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "qdrant_cluster_url" {
  count = local.qdrant_enabled ? 1 : 0

  name        = "${local.qdrant_ssm_path_prefix}/cluster-url"
  description = "Qdrant Cloud cluster gRPC endpoint (https://<host>:6334, TLS on via scheme). Operator-managed value; Terraform creates the SecureString shell only. Consumed by ExternalSecret → K8s Secret `qdrant-credentials` key `QDRANT_URL` in ns `aegis`, referenced by aegis-engine's env mapping (ldz #141 + aegis-core engine_cpp/src/vectordb/qdrant_client.cc)."
  type        = "SecureString"
  key_id      = data.aws_kms_alias.secrets[0].target_key_arn
  value       = "placeholder-operator-must-overwrite"

  tags = merge(local.tags, {
    Name = "qdrant-cloud-cluster-url"
  })

  lifecycle {
    ignore_changes = [value]
  }
}

# -----------------------------------------------------------------------------
# SSM PS — Qdrant Cloud API key (operator-filled)
# -----------------------------------------------------------------------------
# Rotation cadence: Qdrant Cloud free tier issues 90-day keys per Runbook 007.
# Rotation is an out-of-band `put-parameter`; the ExternalSecret's 1h refresh
# interval picks up the new value within the hour.
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "qdrant_api_key" {
  count = local.qdrant_enabled ? 1 : 0

  name        = "${local.qdrant_ssm_path_prefix}/api-key"
  description = "Qdrant Cloud API key — sent as `api-key` gRPC metadata header on every engine request. Operator-managed value; Terraform creates the SecureString shell only. Consumed by ExternalSecret → K8s Secret `qdrant-credentials` key `QDRANT_API_KEY` in ns `aegis`. Rotation per Runbook 007 §API key rotation."
  type        = "SecureString"
  key_id      = data.aws_kms_alias.secrets[0].target_key_arn
  value       = "placeholder-operator-must-overwrite"

  tags = merge(local.tags, {
    Name = "qdrant-cloud-api-key"
  })

  lifecycle {
    ignore_changes = [value]
  }
}

# -----------------------------------------------------------------------------
# ExternalSecret — reconcile Qdrant credentials into ns aegis
# -----------------------------------------------------------------------------
# Dual-gate: qdrant_enabled (feature on) AND platform_applied (cluster exists).
# On cold cycle the ExternalSecret is skipped — AWS SSM resources still
# create cleanly. After `staging/platform` applies (via workload workflow),
# a re-apply of this layer reconciles the ExternalSecret.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "external_secret_qdrant_credentials" {
  count = (local.qdrant_enabled && local.platform_applied) ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "qdrant-credentials"
      namespace = "aegis"
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/part-of"    = "platform"
      }
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "aegis-ssm"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "qdrant-credentials"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "QDRANT_URL"
          remoteRef = {
            key = "${local.qdrant_ssm_path_prefix}/cluster-url"
          }
        },
        {
          secretKey = "QDRANT_API_KEY"
          remoteRef = {
            key = "${local.qdrant_ssm_path_prefix}/api-key"
          }
        },
      ]
    }
  })

  depends_on = [
    aws_ssm_parameter.qdrant_cluster_url,
    aws_ssm_parameter.qdrant_api_key,
  ]
}
