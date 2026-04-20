# -----------------------------------------------------------------------------
# Configuration Contract — ADR-004
# -----------------------------------------------------------------------------

locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id     = local.config.accounts.staging.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]

  # Cluster name convention matches staging/platform: "<prefix>-<slot>".
  # See staging/platform/modules/eks-cluster for the source of truth.
  primary_cluster_name = "aegis-staging-primary"

  tags = merge(local.config.tags, {
    Environment = "staging"
    Component   = "fis"
  })
}

data "aws_caller_identity" "current" {}

check "expected_account" {
  assert {
    condition     = data.aws_caller_identity.current.account_id == local.account_id
    error_message = "Running against the wrong AWS account (${data.aws_caller_identity.current.account_id}) — staging/fis must be applied with credentials for ${local.account_id} (aegis-staging)."
  }
}
