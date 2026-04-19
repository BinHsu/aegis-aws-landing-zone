# -----------------------------------------------------------------------------
# Configuration Contract — ADR-004
# -----------------------------------------------------------------------------
# Every environment reads the same YAML config. No hardcoded account IDs,
# regions, CIDRs, or cluster versions anywhere in Terraform code.
# -----------------------------------------------------------------------------

locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id     = local.config.accounts.staging.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]

  # -----------------------------------------------------------------------------
  # EKS compute footprint — drives per-region VPC instantiation
  # -----------------------------------------------------------------------------
  # Source of truth: config.eks.staging.regions[]. Fallback to a single-region
  # primary when the field is absent — preserves backwards compatibility for
  # forkers who have not yet populated the field.
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

  # VPC sizing per region: accounts.staging.vpcs.<region_name>
  vpc_config_by_region = {
    for r in local.eks_regions : r.region => local.config.accounts.staging.vpcs[r.region]
  }

  # AZ list per region: from the top-level regions[] entry whose name matches
  zones_by_region = {
    for r in local.eks_regions : r.region =>
    [for tr in local.config.regions : tr.zones if tr.name == r.region][0]
  }

  # IPAM pool ID per region. The primary region reads from primary_pool_id;
  # any slave region currently maps to the DR pool (the only non-primary
  # pool provisioned by shared/ipam). A future third region would need a
  # corresponding pool addition upstream.
  ipam_pool_by_region = {
    for r in local.eks_regions : r.region => (
      r.role == "primary"
      ? data.terraform_remote_state.shared_ipam.outputs.primary_pool_id
      : data.terraform_remote_state.shared_ipam.outputs.dr_pool_id
    )
  }

  tags = merge(local.config.tags, {
    Environment = "staging"
    Component   = "network"
  })
}

# -----------------------------------------------------------------------------
# Cross-field invariants — ADR-018 §2
# -----------------------------------------------------------------------------
# Schema catches structural errors; these check blocks catch cross-field
# constraints that JSON Schema cannot express. Plan-time defense in depth
# behind scripts/validate-config.py.
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
    error_message = "Every eks.staging.regions[].region must also appear in the top-level regions[].name list (governance footprint must cover compute footprint)."
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
# Unlike the check blocks above (which surface as warnings and let plan
# continue), this terraform_data precondition HARD-ERRORS at plan time. The
# slot pattern is K=2 by ADR-018 §3; going beyond requires the multi-step
# unlock below, NOT just editing config. If you're reading this message
# because your plan just failed, follow the numbered steps exactly.
# -----------------------------------------------------------------------------
resource "terraform_data" "assert_k2_max" {
  lifecycle {
    precondition {
      condition     = length(local.eks_regions) <= 2
      error_message = <<-EOT
        eks.staging.regions[] has ${length(local.eks_regions)} entries, exceeding the slot-pattern K=2 ceiling declared in ADR-018 §3 "Scaling boundary".

        This project's current slot commitment is TWO regions (primary + one slave). Adding a third region is intentionally made loud — it requires more than a YAML edit because the Terraform provider-alias layer does not support dynamic slot generation (see ADR-018 Alternatives D).

        ## Unlock procedure for K=3 (in order)

          1. Amend docs/decisions/018-multi-region-eks-design.md §3:
             - Change "K=2" to "K=3" in the "Scaling boundary" paragraph
             - Document the third slot in the Consequences section
             - Update the "Amended YYYY-MM-DD" note at the top

          2. In terraform/environments/staging/network/providers.tf:
             - Add a `provider "aws" { alias = "slave_2" ... }` block
               with region driven from `try(local.slave_regions[1].region, local.primary_region)`

          3. In terraform/environments/staging/network/main.tf:
             - Add a `module "vpc_slave_2"` invocation mirroring vpc_slave_1
             - count = `length(local.slave_regions) >= 2 ? 1 : 0`
             - providers = `{ aws.this = aws.slave_2 }`

          4. Mirror steps 2-3 in terraform/environments/staging/platform/:
             - Four provider aliases (aws.slave_2, kubernetes.slave_2, helm.slave_2, kubectl.slave_2)
             - module "cluster_slave_2" invocation

          5. In staging/network/outputs.tf and staging/platform/outputs.tf,
             extend the `vpcs` / `clusters` maps with a `slave_2` entry
             (wrapped in a length >= 2 conditional same as slave_1)

          6. In config/schema.json: bump eks.<env>.regions maxItems from 2 to 3

          7. Bump the `<=` threshold in THIS precondition (both network AND
             platform config.tf) from 2 to 3

          8. Commit the multi-file change as a single PR — reviewers should
             see the whole ceiling bump atomically

        ## Unlock procedure for K > 3 (truly dynamic N)

        The slot pattern stops scaling cleanly around K=4+ (providers.tf
        becomes unwieldy). Instead migrate to a generation-script approach
        documented in ADR-018 §3 escape hatch: `scripts/configure-providers.sh`
        reads config and writes providers.tf at plan time (same idea as the
        existing `scripts/configure-backends.sh`). This is a substantive
        architectural change requiring a new ADR (ADR-020+) because it
        removes providers.tf from source control (generated artifact,
        gitignored), which costs PR-diff reviewability.

        See project memory `project_eks_cluster_module_provider_layout.md`
        for the full rationale behind the slot-pattern choice and why
        module-local providers (which would sidestep the slot cap) are
        rejected by Terraform in the presence of `count`.
      EOT
    }
  }
}

check "vpc_sizing_present_for_every_eks_region" {
  assert {
    condition = alltrue([
      for r in local.eks_regions : contains(keys(local.config.accounts.staging.vpcs), r.region)
    ])
    error_message = "Every eks.staging.regions[].region must have a corresponding accounts.staging.vpcs.<region> entry in config/landing-zone.yaml (providing netmask_length and ipam_pool). See config/landing-zone.example.yaml for the expected shape."
  }
}

# -----------------------------------------------------------------------------
# Cross-layer state reads
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
  # The aws_flow_log resources in each VPC module read the bucket ARN from
  # this remote state so that network destroy does not delete log data.
  backend = "s3"
  config = {
    bucket = "${local.config.organization.name}-terraform-state-${local.config.accounts.shared.id}"
    key    = "staging/bootstrap/terraform.tfstate"
    region = local.primary_region
  }
}
