# -----------------------------------------------------------------------------
# Configuration Contract — ADR-004
# -----------------------------------------------------------------------------

locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id     = local.config.accounts.staging.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]

  cluster_name = "${local.config.organization.name}-staging"

  # From platform remote state — cluster connection details for the
  # kubernetes provider and IRSA trust policy references.
  cluster_endpoint  = data.terraform_remote_state.staging_platform.outputs.cluster_endpoint
  cluster_ca        = data.terraform_remote_state.staging_platform.outputs.cluster_certificate_authority_data
  oidc_provider_arn = data.terraform_remote_state.staging_platform.outputs.oidc_provider_arn
  oidc_provider_url = data.terraform_remote_state.staging_platform.outputs.oidc_provider_url

  tags = merge(local.config.tags, {
    Environment = "staging"
    Component   = "workloads"
  })
}

# -----------------------------------------------------------------------------
# Cross-layer state reads
# -----------------------------------------------------------------------------
# The workloads layer depends on the platform layer (EKS cluster, OIDC
# provider) being applied first. Apply order is enforced by the
# terraform-apply-workload.yml workflow (network → platform → workloads).
# -----------------------------------------------------------------------------

data "terraform_remote_state" "staging_platform" {
  backend = "s3"
  config = {
    bucket = "aegis-terraform-state-345895787808"
    key    = "staging/platform/terraform.tfstate"
    region = "eu-central-1"
  }
}

check "platform_layer_applied" {
  assert {
    condition = (
      data.terraform_remote_state.staging_platform.outputs != null &&
      try(data.terraform_remote_state.staging_platform.outputs.cluster_endpoint, "") != ""
    )
    error_message = "staging/platform has not been applied — cluster_endpoint is empty. Apply staging/platform before staging/workloads (gh workflow run terraform-apply-workload.yml -f env=staging)."
  }
}
