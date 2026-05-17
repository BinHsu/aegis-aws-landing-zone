# -----------------------------------------------------------------------------
# Configuration Contract — ADR-004
# -----------------------------------------------------------------------------
# Peer Terraservice layer for Grafana Cloud downstream identities + the
# primary-only grafana-operator install (ADR-022, ADR-023).
#
# Gate: presence of config.grafana_cloud. Without the block, the whole layer
# plans to zero resources — operator can apply a fresh staging without
# observability, then enable it later by adding grafana_cloud to config and
# re-applying. Mirrors staging/platform/config.tf observability_enabled gate.
#
# This layer targets the PRIMARY cluster only — grafana-operator reconciles
# against a single Grafana Cloud stack; running it in every region would make
# the reconcilers race on identical CRDs (ADR-022 §Multi-region). It is NOT
# part of the per-region orchestration matrix (ADR-032) — it is applied once,
# reading the primary region's platform state.
# -----------------------------------------------------------------------------

locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id     = local.config.accounts.staging.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]

  # Grafana Cloud block — gate for the whole layer.
  grafana_cloud         = try(local.config.grafana_cloud, null)
  observability_enabled = local.grafana_cloud != null

  # Cluster name convention matches staging/platform: "<org>-staging-<region>".
  # grafana-operator + CRDs land on the primary cluster only.
  primary_cluster_name = "${local.config.organization.name}-staging-${local.primary_region}"

  # SSM PS path prefix — ADR-022 §Secret path convention. All Grafana Cloud
  # secrets live under this prefix so IAM policies can scope to the whole
  # family with a single wildcard (staging/platform ESO IRSA does this).
  ssm_path_prefix = "/aegis/staging/grafana-cloud"

  # Qdrant Cloud block — independent gate (ADR-025, ldz #141). Enables the
  # Qdrant scaffold (2 operator-managed SSM PS placeholders + 1 ExternalSecret
  # reconciling into K8s Secret `qdrant-credentials` in ns `aegis`). Lives in
  # this layer by precedent (team-webhooks ExternalSecret pattern), not
  # because Qdrant is an observability concern — see ADR-027 for the layer-
  # sharding discipline that justifies the current placement.
  qdrant_cloud   = try(local.config.qdrant_cloud, null)
  qdrant_enabled = try(local.qdrant_cloud.enabled, false)

  # Qdrant SSM PS path prefix — parallel structure to grafana-cloud. IAM wildcard
  # /aegis/staging/* on ESO IRSA already covers this path, no new IAM needed.
  qdrant_ssm_path_prefix = "/aegis/staging/qdrant-cloud"

  tags = merge(local.config.tags, {
    Environment = "staging"
    Component   = "observability"
  })

  # Cluster details from staging/platform's (region-scoped, primary) flat
  # outputs — ADR-032.
  platform = try(data.terraform_remote_state.staging_platform.outputs, {})

  # platform_applied — derived from whether staging/platform has produced a
  # cluster in its outputs. Gates the Qdrant ExternalSecret kubectl_manifest:
  # without a live cluster the kubectl provider dials an empty host and fails
  # the whole apply. On cold-cycle first apply the operator sees the
  # ExternalSecret skipped, applies staging/platform, and re-applies this
  # layer — the second pass reconciles it.
  platform_applied = try(local.platform.cluster_name, "") != ""
}

# -----------------------------------------------------------------------------
# Cross-layer state read — consume platform's (region-scoped) flat outputs
# -----------------------------------------------------------------------------
# Observability depends on staging/platform (EKS cluster must exist for the
# kubernetes/kubectl/helm providers to connect) AND on staging/workloads (the
# `aegis` namespace must exist for the team-webhooks ExternalSecret). Apply
# ordering is enforced by terraform-apply-workload.yml. This data source is
# the compile-time check that platform has been applied; the workloads
# dependency is ordering-only (enforced by CI).
#
# The cross-field invariants from ADR-018 §2 are validated in
# scripts/validate-config.py — pre-commit, against the whole region list.
# -----------------------------------------------------------------------------

data "terraform_remote_state" "staging_platform" {
  backend = "s3"
  config = {
    bucket = "${local.config.organization.name}-terraform-state-${local.config.accounts.shared.id}"
    # Region-scoped key (ADR-032): observability is primary-only, so it reads
    # the primary region's platform state.
    key    = "staging/${local.primary_region}/platform/terraform.tfstate"
    region = local.primary_region
  }
}

data "aws_caller_identity" "current" {}

check "expected_account" {
  assert {
    condition     = data.aws_caller_identity.current.account_id == local.account_id
    error_message = "Running against the wrong AWS account (${data.aws_caller_identity.current.account_id}) — staging/observability must be applied with credentials for ${local.account_id} (aegis-staging)."
  }
}

check "platform_layer_applied" {
  assert {
    condition = (
      !local.observability_enabled
      || (
        data.terraform_remote_state.staging_platform.outputs != null
        && try(data.terraform_remote_state.staging_platform.outputs.cluster_name, "") != ""
      )
    )
    error_message = "staging/platform has not been applied for the primary region. Apply staging/platform before staging/observability (gh workflow run terraform-apply-workload.yml -f env=staging)."
  }
}

# -----------------------------------------------------------------------------
# SSM PS SecureString encryption key — contract with staging/bootstrap
# -----------------------------------------------------------------------------
# Alias `alias/aegis-staging-secrets` is owned by staging/bootstrap/kms-secrets.tf
# (PR-1 contract). Looked up by alias to avoid chaining bootstrap state into
# this layer. The check below fires a readable error if a forker attempts
# observability before bootstrap.
# -----------------------------------------------------------------------------

data "aws_kms_alias" "secrets" {
  # Shared by grafana-cloud tokens (observability_enabled) and qdrant-cloud
  # SSM placeholders (qdrant_enabled). Any enabled feature in this layer
  # needs the KMS alias; gate accordingly.
  count = (local.observability_enabled || local.qdrant_enabled) ? 1 : 0

  name = "alias/aegis-staging-secrets"
}

check "secrets_kms_key_exists" {
  assert {
    condition = (
      !(local.observability_enabled || local.qdrant_enabled)
      || try(data.aws_kms_alias.secrets[0].target_key_arn, "") != ""
    )
    error_message = "config.grafana_cloud or config.qdrant_cloud is set but KMS alias 'alias/aegis-staging-secrets' is missing. Apply staging/bootstrap first (baseline layer, auto-applied on PR merge — see staging/bootstrap/kms-secrets.tf)."
  }
}

# -----------------------------------------------------------------------------
# Bootstrap token — Runbook 006 Part 2 (human-provisioned, 30-day expiry)
# -----------------------------------------------------------------------------
# Plain `data "aws_ssm_parameter"` returns NoSuchKey when the operator has
# not run Runbook 006 Part 2 yet. That is the intended operator-facing error
# — Part 4 of the runbook documents the `terraform apply` command that
# reaches this data source.
#
# Resource ownership: post-ADR-028, the SSM PS shell lives in
# staging/secrets-persistent/grafana-cloud.tf (baseline-tier, never torn
# down). This data source reads it by path.
# -----------------------------------------------------------------------------

data "aws_ssm_parameter" "bootstrap_token" {
  count = local.observability_enabled ? 1 : 0

  name            = "${local.ssm_path_prefix}/bootstrap-token"
  with_decryption = true
}
