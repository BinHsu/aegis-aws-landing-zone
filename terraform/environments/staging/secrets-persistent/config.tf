# -----------------------------------------------------------------------------
# Configuration Contract — ADR-004, ADR-028
# -----------------------------------------------------------------------------
# Baseline-tier peer layer that owns Path-B SSM PS shells for SaaS
# credentials whose source-of-truth is an external SaaS portal that does
# not retain the value after first display. See ADR-028 for the full
# rationale and the four-resource scope.
#
# Per-credential gating mirrors staging/observability:
#   - grafana_cloud_enabled — config.grafana_cloud block presence
#   - qdrant_enabled        — config.qdrant_cloud.enabled flag
#
# Both gates default false. A fresh fork without either SaaS configured
# plans to zero resources. Adding a feature is a config-only change:
# fill in the relevant block in config/landing-zone.yaml, push, baseline-
# apply CI lights up the corresponding SSM PS shells.
#
# Lifecycle posture (ADR-028 §Decision):
#   - Baseline-tier: auto-apply on merge to main, never torn down by
#     terraform-teardown-workload.yml. The whole point of this layer is
#     that its resources survive workload cycles.
#   - Each SSM PS uses lifecycle.ignore_changes = [value] so the operator-
#     supplied value (put out-of-band per Runbook 006 / 007) is preserved
#     across subsequent applies.
# -----------------------------------------------------------------------------

locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id     = local.config.accounts.staging.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]

  # Per-credential gates. Match staging/observability/config.tf semantics.
  grafana_cloud_enabled = try(local.config.grafana_cloud != null, false)
  qdrant_enabled        = try(local.config.qdrant_cloud.enabled, false)

  # SSM PS path prefixes — locked to the canonical paths read by ESO,
  # data sources elsewhere in the repo, and the IRSA wildcard policy in
  # staging/platform/modules/eks-cluster/external-secrets-iam.tf. Do NOT
  # rename without a coordinated migration (ADR-028 §SSM path prefix
  # unchanged).
  grafana_cloud_ssm_path_prefix = "/aegis/staging/grafana-cloud"
  qdrant_ssm_path_prefix        = "/aegis/staging/qdrant-cloud"

  tags = merge(local.config.tags, {
    Environment = "staging"
    Component   = "secrets-persistent"
  })
}

# -----------------------------------------------------------------------------
# Cross-field invariants
# -----------------------------------------------------------------------------

check "exactly_one_primary_region" {
  assert {
    condition     = length([for r in local.config.regions : r if r.role == "primary"]) == 1
    error_message = "config/landing-zone.yaml regions[] must have exactly one entry with role: primary."
  }
}

# -----------------------------------------------------------------------------
# Account guard
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

check "expected_account" {
  assert {
    condition     = data.aws_caller_identity.current.account_id == local.account_id
    error_message = "Running against the wrong AWS account (${data.aws_caller_identity.current.account_id}) — staging/secrets-persistent must be applied with credentials for ${local.account_id} (aegis-staging)."
  }
}

# -----------------------------------------------------------------------------
# SSM PS SecureString encryption key — contract with staging/bootstrap
# -----------------------------------------------------------------------------
# Same KMS alias as staging/observability and staging/auth. Looked up by
# alias to avoid chaining bootstrap state into this layer.
# -----------------------------------------------------------------------------

data "aws_kms_alias" "secrets" {
  count = (local.grafana_cloud_enabled || local.qdrant_enabled) ? 1 : 0

  name = "alias/aegis-staging-secrets"
}

check "secrets_kms_key_exists" {
  assert {
    condition = (
      !(local.grafana_cloud_enabled || local.qdrant_enabled)
      || try(data.aws_kms_alias.secrets[0].target_key_arn, "") != ""
    )
    error_message = "config.grafana_cloud or config.qdrant_cloud is set but KMS alias 'alias/aegis-staging-secrets' is missing. Apply staging/bootstrap first (baseline layer, auto-applied on PR merge — see staging/bootstrap/kms-secrets.tf)."
  }
}
