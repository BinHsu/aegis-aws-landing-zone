# -----------------------------------------------------------------------------
# Qdrant Cloud persistent SaaS-credential SSM PS shells (ADR-028)
# -----------------------------------------------------------------------------
# Two parameters: cluster-url + api-key. Both Path-B — operator copies
# values from the Qdrant Cloud portal once at onboarding and rotates the
# api-key per Runbook 007 §API key rotation (90-day cadence).
#
# Both resources were originally scaffolded in staging/observability/
# qdrant-scaffold.tf (PR #146, ldz #141). Migrated here by ADR-028
# after Incident 33's teardown destroyed both values: the api-key is
# one-time-display from the portal, so destroy loss = manual portal
# revisit + key re-issuance. Living in this baseline-tier layer means
# routine workload teardowns can no longer destroy them.
#
# IRSA policy in staging/platform/modules/eks-cluster/external-secrets-iam.tf
# scopes ESO read access via wildcard `/aegis/staging/qdrant-cloud/*` —
# unchanged. The ExternalSecret CRD that consumes these parameters
# remains in staging/observability/qdrant-scaffold.tf (ADR-028 §
# ExternalSecret CRDs stay in observability).
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# 1. cluster-url — Qdrant Cloud gRPC endpoint
# -----------------------------------------------------------------------------
# Format: https://<cluster-uuid>.eu-central-1-0.aws.cloud.qdrant.io:6334
# The engine's qdrant_client infers TLS from the URL scheme — bare host
# means plaintext. See engine_cpp/src/vectordb/qdrant_client.cc:132 in
# aegis-core.
#
# Operator fills via:
#
#   aws ssm put-parameter \
#     --region eu-central-1 \
#     --name /aegis/staging/qdrant-cloud/cluster-url \
#     --type SecureString --key-id alias/aegis-staging-secrets \
#     --value 'https://<cluster-uuid>.eu-central-1-0.aws.cloud.qdrant.io:6334' \
#     --overwrite
#
# The cluster URL is stable across api-key rotations — only re-put if
# the cluster itself is destroyed and re-provisioned.
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "qdrant_cluster_url" {
  count = local.qdrant_enabled ? 1 : 0

  name        = "${local.qdrant_ssm_path_prefix}/cluster-url"
  description = "Qdrant Cloud cluster gRPC endpoint (https://<host>:6334, TLS on via scheme). Operator-managed value; Terraform owns the SecureString shell only. Provisioned by terraform/environments/staging/secrets-persistent/ (ADR-028 — moved from staging/observability/ after Incident 33). Consumed by ExternalSecret → K8s Secret `qdrant-credentials` key `QDRANT_URL` in ns `aegis` (ldz #141)."
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
# 2. api-key — Qdrant Cloud API key (90-day rotation per Runbook 007)
# -----------------------------------------------------------------------------
# Sent as `api-key` gRPC metadata header on every engine request. Lost
# this once already (Incident 33 + 34) — relocating to this layer means
# the next teardown does not destroy it.
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "qdrant_api_key" {
  count = local.qdrant_enabled ? 1 : 0

  name        = "${local.qdrant_ssm_path_prefix}/api-key"
  description = "Qdrant Cloud API key — sent as `api-key` gRPC metadata header on every engine request. Operator-managed value; Terraform owns the SecureString shell only. Provisioned by terraform/environments/staging/secrets-persistent/ (ADR-028 — moved from staging/observability/ after Incident 33). Consumed by ExternalSecret → K8s Secret `qdrant-credentials` key `QDRANT_API_KEY` in ns `aegis`. Rotation per Runbook 007 §API key rotation."
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
