locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id     = local.config.accounts.staging.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]

  # Zones for the primary region, from config
  primary_zones = [for r in local.config.regions : r.zones if r.name == local.primary_region][0]

  # VPC sizing from config (accounts.staging.vpcs.<region>)
  vpc_config = local.config.accounts.staging.vpcs[local.primary_region]

  tags = merge(local.config.tags, {
    Environment = "staging"
    Component   = "network"
  })
}

check "exactly_one_primary_region" {
  assert {
    condition     = length([for r in local.config.regions : r if r.role == "primary"]) == 1
    error_message = "config/landing-zone.yaml regions[] must have exactly one entry with role: primary."
  }
}

# Cross-layer state reads
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
  # The aws_flow_log resource in flow-logs.tf reads the bucket ARN from
  # this remote state so that network destroy does not delete log data.
  backend = "s3"
  config = {
    bucket = "${local.config.organization.name}-terraform-state-${local.config.accounts.shared.id}"
    key    = "staging/bootstrap/terraform.tfstate"
    region = local.primary_region
  }
}
