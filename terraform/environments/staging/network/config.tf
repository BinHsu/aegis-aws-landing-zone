# -----------------------------------------------------------------------------
# Configuration Contract — ADR-004
# -----------------------------------------------------------------------------
# Every environment reads the same YAML config. No hardcoded account IDs,
# regions, CIDRs, or cluster versions anywhere in Terraform code.
#
# Multi-region model — ADR-032: this layer handles ONE region per apply
# (var.region). The multi-region loop is external (Makefile / CI matrix).
# -----------------------------------------------------------------------------

locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id     = local.config.accounts.staging.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]

  # The single region this apply targets. var.region is injected by the
  # orchestrator; the `region_is_configured` check below validates it.
  region     = var.region
  is_primary = local.region == local.primary_region

  # VPC sizing for this region: accounts.staging.vpcs.<region>
  vpc_config = local.config.accounts.staging.vpcs[local.region]

  # AZ list for this region: from the top-level regions[] entry that matches.
  zones = [for tr in local.config.regions : tr.zones if tr.name == local.region][0]

  # IPAM pool: the primary region allocates from the primary pool; any other
  # region allocates from the DR pool (the only non-primary pool provisioned
  # by shared/ipam). A third distinct region would need a new pool upstream.
  ipam_pool_id = (
    local.is_primary
    ? data.terraform_remote_state.shared_ipam.outputs.primary_pool_id
    : data.terraform_remote_state.shared_ipam.outputs.dr_pool_id
  )

  tags = merge(local.config.tags, {
    Environment = "staging"
    Component   = "network"
  })
}

# -----------------------------------------------------------------------------
# Plan-time guards
# -----------------------------------------------------------------------------
# The cross-field invariants from ADR-018 §2 (exactly-one-primary, subset,
# uniqueness) are validated in scripts/validate-config.py — pre-commit, against
# the whole region list. A single-region apply has no list to cross-check; it
# only needs to confirm the one region it was handed is actually configured.
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

check "vpc_sizing_present" {
  assert {
    condition     = contains(keys(local.config.accounts.staging.vpcs), local.region)
    error_message = "accounts.staging.vpcs.${local.region} is missing in config/landing-zone.yaml (it provides netmask_length). See config/landing-zone.example.yaml for the expected shape."
  }
}

# -----------------------------------------------------------------------------
# Cross-layer state reads
# -----------------------------------------------------------------------------
# These read baseline layers (shared/ipam, staging/bootstrap), which are
# single-region and NOT region-scoped — their keys are unchanged. The state
# bucket lives in the shared account, in the primary region.
# -----------------------------------------------------------------------------

data "terraform_remote_state" "shared_ipam" {
  backend = "s3"
  config = {
    bucket = "${local.config.organization.name}-terraform-state-${local.config.accounts.shared.id}"
    key    = "shared/ipam/terraform.tfstate"
    region = local.primary_region
  }
}

data "terraform_remote_state" "staging_bootstrap" {
  # Flow Logs S3 bucket lives in bootstrap (persistent across teardown).
  # The aws_flow_log resource in the VPC module reads the bucket ARN from
  # this remote state so that network destroy does not delete log data.
  backend = "s3"
  config = {
    bucket = "${local.config.organization.name}-terraform-state-${local.config.accounts.shared.id}"
    key    = "staging/bootstrap/terraform.tfstate"
    region = local.primary_region
  }
}
