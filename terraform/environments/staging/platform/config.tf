# -----------------------------------------------------------------------------
# Configuration Contract — ADR-004
# -----------------------------------------------------------------------------
# Multi-region model — ADR-032: this layer handles ONE EKS cluster, in one
# region (var.region), per apply. The multi-region loop is external.
# -----------------------------------------------------------------------------

locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id     = local.config.accounts.staging.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]

  # The single region this apply targets.
  region     = var.region
  is_primary = local.region == local.primary_region

  # -----------------------------------------------------------------------------
  # Grafana Cloud observability — optional per ADR-022
  # -----------------------------------------------------------------------------
  # Presence of config.grafana_cloud gates the whole platform observability
  # stack (ESO, prometheus-operator-crds, kube-state-metrics, Alloy). A forker
  # can omit this block and deploy the EKS platform without observability;
  # re-applying with grafana_cloud populated adds the stack idempotently.
  # -----------------------------------------------------------------------------
  grafana_cloud         = try(local.config.grafana_cloud, null)
  observability_enabled = local.grafana_cloud != null

  # AZ list for this region — from the top-level regions[] entry that matches.
  zones = [for tr in local.config.regions : tr.zones if tr.name == local.region][0]

  eks_version         = local.config.eks.staging.version
  public_access_cidrs = local.config.eks.staging.public_access_cidrs

  # Cluster name: <org>-staging-<region>, e.g. aegis-staging-eu-central-1.
  # The <org>-staging prefix is pre-existing (no churn per CLAUDE.md); only
  # the suffix changed from a slot label (-primary / -slave-1) to the region.
  cluster_name_base = "${local.config.organization.name}-staging"
  cluster_name      = "${local.cluster_name_base}-${local.region}"

  # Cluster-admin EKS Access Entry principal — must match the role that
  # actually performs `terraform apply` on this layer. Per ADR-029 PR-6,
  # `terraform-apply-workload.yml` assumes `gh-tf-apply-workload`. The in-TF
  # `helm` / `kubernetes` / `kubectl` providers need cluster-admin to install
  # Karpenter / ArgoCD / Kyverno / cert-manager / ESO during apply.
  ci_role_arn = "arn:aws:iam::${local.account_id}:role/gh-tf-apply-workload"

  tags = merge(local.config.tags, {
    Environment = "staging"
    Component   = "platform"
  })
}

# -----------------------------------------------------------------------------
# Plan-time guards
# -----------------------------------------------------------------------------
# The cross-field invariants from ADR-018 §2 (exactly-one-primary, subset,
# uniqueness) are validated in scripts/validate-config.py — pre-commit, against
# the whole region list. A single-region apply only needs to confirm the one
# region it was handed is actually configured.
# -----------------------------------------------------------------------------

check "config_eks_section_present" {
  assert {
    condition     = contains(keys(local.config), "eks") && contains(keys(local.config.eks), "staging")
    error_message = "config/landing-zone.yaml is missing eks.staging section. See config/landing-zone.example.yaml and ADR-013."
  }
}

check "region_is_configured" {
  assert {
    condition = contains(
      [for r in try(local.config.eks.staging.regions, []) : r.region],
      local.region
    )
    error_message = "var.region (${local.region}) is not listed in eks.staging.regions[] in config/landing-zone.yaml. The orchestrator should only apply configured regions."
  }
}

# -----------------------------------------------------------------------------
# Cross-layer state reads
# -----------------------------------------------------------------------------

data "terraform_remote_state" "staging_network" {
  # Region-scoped key (ADR-032): platform reads the network state for the
  # SAME region this apply targets.
  backend = "s3"
  config = {
    bucket = "${local.config.organization.name}-terraform-state-${local.config.accounts.shared.id}"
    key    = "staging/${local.region}/network/terraform.tfstate"
    region = local.primary_region
  }
}

data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# SSM PS SecureString encryption key — created in staging/bootstrap (ADR-022)
# -----------------------------------------------------------------------------
# Looked up by alias rather than via terraform_remote_state so platform
# state does not depend on bootstrap state at plan time. Alias is a stable
# contract (`alias/aegis-staging-secrets`) owned by staging/bootstrap/
# kms-secrets.tf; the check block below produces a readable error if a
# forker applies platform before bootstrap.
# -----------------------------------------------------------------------------

data "aws_kms_alias" "secrets" {
  count = local.observability_enabled ? 1 : 0

  name = "alias/aegis-staging-secrets"
}

check "secrets_kms_key_exists" {
  assert {
    condition = (
      !local.observability_enabled
      || try(data.aws_kms_alias.secrets[0].target_key_arn, "") != ""
    )
    error_message = "config.grafana_cloud is set but KMS alias 'alias/aegis-staging-secrets' is missing. Apply staging/bootstrap first (baseline layer, auto-applied on PR merge — see staging/bootstrap/kms-secrets.tf)."
  }
}

check "network_layer_applied" {
  assert {
    condition = (
      data.terraform_remote_state.staging_network.outputs != null &&
      try(data.terraform_remote_state.staging_network.outputs.vpc_id, "") != ""
    )
    error_message = "staging/network has not been applied for region ${local.region} — vpc_id is empty. Apply staging/network for this region first (gh workflow run terraform-apply-workload.yml -f env=staging)."
  }
}
