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
# Unlike staging/platform (which is slot-patterned K=2), this layer targets
# the PRIMARY cluster only — grafana-operator reconciles against a single
# Grafana Cloud stack; running it in both slots would make the two
# reconcilers race on identical CRDs (ADR-022 §Multi-region primary-only
# rationale). There is no slave_1 provider and no slot pattern here.
# -----------------------------------------------------------------------------

locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id     = local.config.accounts.staging.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]

  # Grafana Cloud block — gate for the whole layer.
  grafana_cloud         = try(local.config.grafana_cloud, null)
  observability_enabled = local.grafana_cloud != null

  # -----------------------------------------------------------------------------
  # EKS compute footprint — mirrored from staging/platform so the K=2 ceiling
  # precondition can assert in this layer too. Not used for slot expansion
  # (grafana-operator is primary-only per ADR-022 §Multi-region); consulted
  # only for the precondition guard and a clearer error message when a
  # forker tries to push past K=2.
  # -----------------------------------------------------------------------------
  eks_regions = try(
    local.config.eks.staging.regions,
    [{
      region = local.primary_region
      role   = "primary"
      mode   = "active"
    }]
  )

  primary_eks_region = [for r in local.eks_regions : r if r.role == "primary"][0]

  # Cluster name convention matches staging/platform: "<org>-staging-<slot>".
  # grafana-operator + CRDs land on the primary cluster only.
  primary_cluster_name = "${local.config.organization.name}-staging-primary"

  # SSM PS path prefix — ADR-022 §Secret path convention. All Grafana Cloud
  # secrets live under this prefix so IAM policies can scope to the whole
  # family with a single wildcard (staging/platform ESO IRSA does this).
  ssm_path_prefix = "/aegis/staging/grafana-cloud"

  # Qdrant Cloud block — independent gate (ADR-025, ldz #141). Enables the
  # Qdrant scaffold (2 operator-managed SSM PS placeholders + 1 ExternalSecret
  # reconciling into K8s Secret `qdrant-credentials` in ns `aegis`). Lives in
  # this layer by precedent (team-webhooks ExternalSecret pattern), not
  # because Qdrant is an observability concern — see ADR-027 for the layer-
  # sharding discipline that justifies the current placement + enumerates
  # triggers for future extraction to `staging/data-secrets/`.
  qdrant_cloud   = try(local.config.qdrant_cloud, null)
  qdrant_enabled = try(local.qdrant_cloud.enabled, false)

  # Qdrant SSM PS path prefix — parallel structure to grafana-cloud. IAM wildcard
  # /aegis/staging/* on ESO IRSA already covers this path, no new IAM needed.
  qdrant_ssm_path_prefix = "/aegis/staging/qdrant-cloud"

  tags = merge(local.config.tags, {
    Environment = "staging"
    Component   = "observability"
  })

  # Per-cluster details read from staging/platform's per-slot clusters map.
  clusters = try(data.terraform_remote_state.staging_platform.outputs.clusters, {})

  # platform_applied — derived from whether staging/platform has produced a
  # `primary` cluster in its outputs. Gates the Qdrant ExternalSecret
  # kubectl_manifest: without a live cluster the kubectl provider dials an
  # empty host and fails the whole apply. On cold-cycle first apply the
  # operator sees the ExternalSecret skipped, applies staging/platform (via
  # workloads), and re-applies this layer — the second pass reconciles it.
  # Identical pattern to staging/auth/config.tf (PR #142).
  platform_applied = try(contains(keys(local.clusters), "primary"), false)
}

# -----------------------------------------------------------------------------
# Cross-field invariants — ADR-018 §2 (mirror of staging/platform checks)
# -----------------------------------------------------------------------------

check "exactly_one_primary_region_top_level" {
  assert {
    condition     = length([for r in local.config.regions : r if r.role == "primary"]) == 1
    error_message = "config/landing-zone.yaml regions[] must have exactly one entry with role: primary."
  }
}

check "exactly_one_primary_eks_region" {
  assert {
    condition     = length([for r in local.eks_regions : r if r.role == "primary"]) == 1
    error_message = "config/landing-zone.yaml eks.staging.regions[] must have exactly one entry with role: primary."
  }
}

# -----------------------------------------------------------------------------
# K=2 slot ceiling — mirror of the same guard in network/, platform/,
# workloads/. Observability is primary-only but must still refuse to plan
# when the top-level config exceeds K=2 — otherwise a forker could drift
# the sibling layers into K=3 state while observability silently applies.
# -----------------------------------------------------------------------------

resource "terraform_data" "assert_k2_max" {
  lifecycle {
    precondition {
      condition     = length(local.eks_regions) <= 2
      error_message = <<-EOT
        eks.staging.regions[] has ${length(local.eks_regions)} entries, exceeding the slot-pattern K=2 ceiling declared in ADR-018 §3 "Scaling boundary".

        See the detailed unlock procedure in terraform/environments/staging/network/config.tf — single source of truth.

        Note: this layer (staging/observability) is intentionally primary-only per ADR-022 §Multi-region. The K=2 guard exists here because a K=3 top-level config is a repo-wide governance breach; refusing to plan is safer than silently applying one layer past the ceiling.
      EOT
    }
  }
}

# -----------------------------------------------------------------------------
# Cross-layer state read — consume platform's clusters map
# -----------------------------------------------------------------------------
# Observability is a peer layer that depends on staging/platform (EKS cluster
# must exist for the kubernetes/kubectl/helm providers to connect) AND on
# staging/workloads (the `aegis` namespace must exist for the team-webhooks
# ExternalSecret to land in that namespace). Apply ordering is enforced by
# the terraform-apply-workload.yml workflow: network → platform → workloads
# → observability. This data source is the compile-time check that platform
# has been applied; workloads dependency is ordering-only (enforced by CI).
# -----------------------------------------------------------------------------

data "terraform_remote_state" "staging_platform" {
  backend = "s3"
  config = {
    bucket = "${local.config.organization.name}-terraform-state-${local.config.accounts.shared.id}"
    key    = "staging/platform/terraform.tfstate"
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
        && try(contains(keys(data.terraform_remote_state.staging_platform.outputs.clusters), "primary"), false)
      )
    )
    error_message = "staging/platform has not been applied or its clusters map is missing the primary slot. Apply staging/platform before staging/observability (gh workflow run terraform-apply-workload.yml -f env=staging)."
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
# down). This data source reads it by path — TF state ownership of the
# shell is irrelevant to the lookup. Pre-ADR-028 the parameter had no TF
# resource shell at all (operator-only via Runbook 006 §Part 2);
# secrets-persistent's `import { }` block adopts it on first apply.
# -----------------------------------------------------------------------------

data "aws_ssm_parameter" "bootstrap_token" {
  count = local.observability_enabled ? 1 : 0

  name            = "${local.ssm_path_prefix}/bootstrap-token"
  with_decryption = true
}
