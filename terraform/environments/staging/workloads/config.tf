# -----------------------------------------------------------------------------
# Configuration Contract — ADR-004
# -----------------------------------------------------------------------------
# Multi-region model — ADR-032: this layer handles workloads on ONE cluster,
# in one region (var.region), per apply. The multi-region loop is external.
# -----------------------------------------------------------------------------

locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id     = local.config.accounts.staging.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]

  # The single region this apply targets.
  region = var.region

  tags = merge(local.config.tags, {
    Environment = "staging"
    Component   = "workloads"
  })

  # Cluster details from staging/platform's (region-scoped) flat outputs.
  cluster = data.terraform_remote_state.staging_platform.outputs
}

# -----------------------------------------------------------------------------
# Plan-time guards
# -----------------------------------------------------------------------------
# The cross-field invariants from ADR-018 §2 are validated in
# scripts/validate-config.py — pre-commit, against the whole region list.
# -----------------------------------------------------------------------------

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
# Cross-layer state read — consume platform's (region-scoped) flat outputs
# -----------------------------------------------------------------------------
# The workloads layer depends on the platform layer (EKS cluster, OIDC
# provider) being applied first for the SAME region. Apply order is enforced
# by the terraform-apply-workload.yml workflow (network → platform → workloads
# per region).
# -----------------------------------------------------------------------------

data "terraform_remote_state" "staging_platform" {
  backend = "s3"
  config = {
    bucket = "${local.config.organization.name}-terraform-state-${local.config.accounts.shared.id}"
    key    = "staging/${local.region}/platform/terraform.tfstate"
    region = local.primary_region
  }
}

check "platform_layer_applied" {
  assert {
    condition = (
      data.terraform_remote_state.staging_platform.outputs != null &&
      try(data.terraform_remote_state.staging_platform.outputs.cluster_name, "") != ""
    )
    error_message = "staging/platform has not been applied for region ${local.region} — cluster_name is empty. Apply staging/platform for this region before staging/workloads (gh workflow run terraform-apply-workload.yml -f env=staging)."
  }
}
