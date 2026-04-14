# -----------------------------------------------------------------------------
# Configuration Contract — ADR-004
# -----------------------------------------------------------------------------
# Every environment reads the same YAML config. No hardcoded account IDs,
# regions, CIDRs, or cluster versions anywhere in Terraform code.
# -----------------------------------------------------------------------------

locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  # Convenience aliases used across this environment
  account_id     = local.config.accounts.staging.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]

  # Zones for the primary region, consumed by Karpenter NodePool topology
  # constraints (karpenter-nodepool.tf).
  primary_zones = [for r in local.config.regions : r.zones if r.name == local.primary_region][0]

  # EKS platform settings from config/landing-zone.yaml → eks.staging.
  # See ADR-013 for the design of these fields and docs/runbooks/002-eks-access.md
  # for the operational contract behind public_access_cidrs.
  eks_version         = local.config.eks.staging.version
  public_access_cidrs = local.config.eks.staging.public_access_cidrs

  cluster_name = "${local.config.organization.name}-staging"

  tags = merge(local.config.tags, {
    Environment = "staging"
    Component   = "platform"
  })
}

# -----------------------------------------------------------------------------
# Cross-layer state reads
# -----------------------------------------------------------------------------
# The platform layer depends on the network layer (VPC, subnets) being
# applied first. Apply order is enforced operationally by the
# terraform-apply-workload.yml workflow (network → platform → workloads).
# If the network state is missing or empty, Terraform plan fails with a
# clear error on the subnet reference below.
# -----------------------------------------------------------------------------

data "terraform_remote_state" "staging_network" {
  backend = "s3"
  config = {
    bucket = "aegis-terraform-state-345895787808"
    key    = "staging/network/terraform.tfstate"
    region = "eu-central-1"
  }
}

data "aws_caller_identity" "current" {}

check "config_eks_section_present" {
  assert {
    condition     = contains(keys(local.config), "eks") && contains(keys(local.config.eks), "staging")
    error_message = "config/landing-zone.yaml is missing eks.staging section. See config/landing-zone.example.yaml and ADR-013."
  }
}

check "network_layer_applied" {
  assert {
    condition = (
      data.terraform_remote_state.staging_network.outputs != null &&
      length(try(data.terraform_remote_state.staging_network.outputs.private_subnet_ids, [])) > 0
    )
    error_message = "staging/network has not been applied — private_subnet_ids is empty. Apply staging/network before staging/platform (gh workflow run terraform-apply-workload.yml -f env=staging)."
  }
}
