# -----------------------------------------------------------------------------
# Configuration Contract — ADR-004
# -----------------------------------------------------------------------------

locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id     = local.config.accounts.staging.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]

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

  # -----------------------------------------------------------------------------
  # EKS compute footprint — drives per-cluster module instantiation
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

  # AZ list per region — from the top-level regions[] entry whose name matches
  zones_by_region = {
    for r in local.eks_regions : r.region =>
    [for tr in local.config.regions : tr.zones if tr.name == r.region][0]
  }

  eks_version         = local.config.eks.staging.version
  public_access_cidrs = local.config.eks.staging.public_access_cidrs

  cluster_name_base = "${local.config.organization.name}-staging"

  ci_role_arn = "arn:aws:iam::${local.account_id}:role/github-actions-terraform"

  tags = merge(local.config.tags, {
    Environment = "staging"
    Component   = "platform"
  })
}

# -----------------------------------------------------------------------------
# Cross-field invariants — ADR-018 §2
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
# K=2 slot ceiling — hard error, not a warning
# -----------------------------------------------------------------------------
# Duplicated in staging/network/config.tf. The full unlock procedure lives
# there (single source of truth). The guard must exist in BOTH layers
# because either layer can be planned/applied independently; missing the
# guard in one would leave half the infrastructure attempting K=3 while
# the other refuses.
# -----------------------------------------------------------------------------
resource "terraform_data" "assert_k2_max" {
  lifecycle {
    precondition {
      condition     = length(local.eks_regions) <= 2
      error_message = <<-EOT
        eks.staging.regions[] has ${length(local.eks_regions)} entries, exceeding the slot-pattern K=2 ceiling declared in ADR-018 §3 "Scaling boundary".

        See the detailed unlock procedure in terraform/environments/staging/network/config.tf — it walks through the eight-step multi-file edit required to add a K=3 slot. Same error, same procedure; duplicating it here would let the two copies drift.

        TL;DR: amend ADR-018 §3, add slave_2 provider alias + module invocation in BOTH staging/network/ and staging/platform/, extend outputs maps, bump schema.json maxItems, bump the `<=` threshold in both config.tf files.
      EOT
    }
  }
}

check "config_eks_section_present" {
  assert {
    condition     = contains(keys(local.config), "eks") && contains(keys(local.config.eks), "staging")
    error_message = "config/landing-zone.yaml is missing eks.staging section. See config/landing-zone.example.yaml and ADR-013."
  }
}

# -----------------------------------------------------------------------------
# Cross-layer state reads — consume network's new per-region output map
# -----------------------------------------------------------------------------

data "terraform_remote_state" "staging_network" {
  backend = "s3"
  config = {
    bucket = "${local.config.organization.name}-terraform-state-${local.config.accounts.shared.id}"
    key    = "staging/network/terraform.tfstate"
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
      length(try(keys(data.terraform_remote_state.staging_network.outputs.vpcs), [])) > 0
    )
    error_message = "staging/network has not been applied — vpcs map is empty. Apply staging/network before staging/platform (gh workflow run terraform-apply-workload.yml -f env=staging)."
  }
}
