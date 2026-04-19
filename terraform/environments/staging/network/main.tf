# -----------------------------------------------------------------------------
# Staging VPCs — ADR-012 topology, ADR-018 multi-region
# -----------------------------------------------------------------------------
# One module invocation per entry in eks.staging.regions[]. Provider alias
# is the slot pattern: always two aliases (primary, slave_1), growing requires
# ADR amendment. All region-specific resources live inside the module so the
# top level stays small and reviewable.
#
# State structure: single state file for the layer — all invocations share
# `staging/network/terraform.tfstate`. Per ADR-018 §4.
# -----------------------------------------------------------------------------

locals {
  # flow_logs_bucket_arn is read once at layer scope and passed into each
  # module. Null-safe: if bootstrap has not been applied, the VPC module
  # skips the aws_flow_log resource entirely (see module flow-logs.tf).
  flow_logs_bucket_arn = try(
    data.terraform_remote_state.staging_bootstrap.outputs.flow_logs_bucket_arn,
    null
  )
}

module "vpc_primary" {
  source = "./modules/vpc"

  providers = {
    aws.this = aws.primary
  }

  region_key           = "primary"
  region_name          = local.primary_eks_region.region
  zones                = local.zones_by_region[local.primary_eks_region.region]
  netmask_length       = local.vpc_config_by_region[local.primary_eks_region.region].netmask_length
  ipam_pool_id         = local.ipam_pool_by_region[local.primary_eks_region.region]
  flow_logs_bucket_arn = local.flow_logs_bucket_arn
  env_name             = "staging"
}

module "vpc_slave_1" {
  source = "./modules/vpc"

  count = length(local.slave_regions) >= 1 ? 1 : 0

  providers = {
    aws.this = aws.slave_1
  }

  region_key           = "slave_1"
  region_name          = try(local.slave_regions[0].region, local.primary_region)
  zones                = try(local.zones_by_region[local.slave_regions[0].region], [])
  netmask_length       = try(local.vpc_config_by_region[local.slave_regions[0].region].netmask_length, 20)
  ipam_pool_id         = try(local.ipam_pool_by_region[local.slave_regions[0].region], "")
  flow_logs_bucket_arn = local.flow_logs_bucket_arn
  env_name             = "staging"
}

check "ipam_pool_available" {
  assert {
    condition     = data.terraform_remote_state.shared_ipam.outputs.primary_pool_id != ""
    error_message = "shared/ipam has not been applied. Apply shared/ipam before staging/network."
  }
}
