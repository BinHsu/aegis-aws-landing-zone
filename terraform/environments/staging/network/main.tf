# -----------------------------------------------------------------------------
# Staging VPC — ADR-012 topology, ADR-032 external-orchestration multi-region
# -----------------------------------------------------------------------------
# One VPC, in the single region this apply targets (var.region). The
# multi-region fan-out is external: the orchestrator runs this layer once per
# entry in eks.staging.regions[], each with its own region-scoped state key.
#
# All region-specific resources live inside ./modules/vpc so the top level
# stays small and reviewable.
# -----------------------------------------------------------------------------

locals {
  # flow_logs_bucket_arn is null-safe: if bootstrap has not been applied, the
  # VPC module skips the aws_flow_log resource entirely (see module
  # flow-logs.tf).
  flow_logs_bucket_arn = try(
    data.terraform_remote_state.staging_bootstrap.outputs.flow_logs_bucket_arn,
    null
  )
}

module "vpc" {
  source = "./modules/vpc"

  region               = local.region
  zones                = local.zones
  netmask_length       = local.vpc_config.netmask_length
  ipam_pool_id         = local.ipam_pool_id
  flow_logs_bucket_arn = local.flow_logs_bucket_arn
  env_name             = "staging"
}

check "ipam_pool_available" {
  assert {
    condition     = data.terraform_remote_state.shared_ipam.outputs.primary_pool_id != ""
    error_message = "shared/ipam has not been applied. Apply shared/ipam before staging/network."
  }
}
