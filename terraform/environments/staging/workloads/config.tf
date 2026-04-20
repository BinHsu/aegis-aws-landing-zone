# -----------------------------------------------------------------------------
# Configuration Contract — ADR-004
# -----------------------------------------------------------------------------

locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id     = local.config.accounts.staging.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]

  # -----------------------------------------------------------------------------
  # EKS compute footprint — drives per-cluster module instantiation.
  # Same shape as staging/platform/config.tf (single source of truth in the
  # config file). Length 1 = primary only; length 2 = primary + slave_1.
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
  slave_regions      = [for r in local.eks_regions : r if r.role != "primary"]

  tags = merge(local.config.tags, {
    Environment = "staging"
    Component   = "workloads"
  })

  # -----------------------------------------------------------------------------
  # Per-slot cluster details — sourced from staging/platform's outputs.clusters
  # map (PR #92). Key = slot name (primary, slave_1, ...).
  # -----------------------------------------------------------------------------
  clusters = data.terraform_remote_state.staging_platform.outputs.clusters
}

# -----------------------------------------------------------------------------
# Cross-field invariants — ADR-018 §2 (mirrors staging/platform/config.tf)
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

check "eks_regions_subset_of_top_level" {
  assert {
    condition = alltrue([
      for r in local.eks_regions :
      contains([for tr in local.config.regions : tr.name], r.region)
    ])
    error_message = "Every eks.staging.regions[].region must appear in top-level regions[].name (governance covers compute footprint)."
  }
}

check "eks_region_names_unique" {
  assert {
    condition     = length(local.eks_regions) == length(distinct([for r in local.eks_regions : r.region]))
    error_message = "eks.staging.regions[].region entries must be unique."
  }
}

# -----------------------------------------------------------------------------
# K=2 slot ceiling — hard error, not a warning.
# Mirrors staging/network/config.tf and staging/platform/config.tf. The guard
# must exist in EVERY layer that participates in the slot pattern; otherwise
# applying just one layer with K=3 config would let it drift past the
# ceiling while the others refuse.
# -----------------------------------------------------------------------------
resource "terraform_data" "assert_k2_max" {
  lifecycle {
    precondition {
      condition     = length(local.eks_regions) <= 2
      error_message = <<-EOT
        eks.staging.regions[] has ${length(local.eks_regions)} entries, exceeding the slot-pattern K=2 ceiling declared in ADR-018 §3 "Scaling boundary".

        See the detailed unlock procedure in terraform/environments/staging/network/config.tf — single source of truth, walks through the multi-file edit required to add a K=3 slot.

        TL;DR: amend ADR-018 §3, add slave_2 provider alias + module invocation in staging/network/, staging/platform/, AND staging/workloads/, extend outputs maps, bump schema.json maxItems, bump the `<=` threshold in all three config.tf files.
      EOT
    }
  }
}

# -----------------------------------------------------------------------------
# Cross-layer state reads — consume platform's per-slot clusters map (PR #92)
# -----------------------------------------------------------------------------
# The workloads layer depends on the platform layer (EKS clusters, OIDC
# providers) being applied first. Apply order is enforced by the
# terraform-apply-workload.yml workflow (network → platform → workloads).
# -----------------------------------------------------------------------------

data "terraform_remote_state" "staging_platform" {
  backend = "s3"
  config = {
    bucket = "${local.config.organization.name}-terraform-state-${local.config.accounts.shared.id}"
    key    = "staging/platform/terraform.tfstate"
    region = local.primary_region
  }
}

check "platform_layer_applied" {
  assert {
    condition = (
      data.terraform_remote_state.staging_platform.outputs != null &&
      try(length(keys(data.terraform_remote_state.staging_platform.outputs.clusters)), 0) > 0
    )
    error_message = "staging/platform has not been applied — clusters map is empty. Apply staging/platform before staging/workloads (gh workflow run terraform-apply-workload.yml -f env=staging)."
  }
}

check "platform_clusters_match_eks_regions" {
  assert {
    condition = alltrue([
      for r in local.eks_regions :
      contains(keys(try(data.terraform_remote_state.staging_platform.outputs.clusters, {})), r.role == "primary" ? "primary" : "slave_1")
    ])
    error_message = "Mismatch between eks.staging.regions[] (workloads side) and platform's clusters map. Re-apply staging/platform with the same eks.staging.regions config before applying workloads."
  }
}
