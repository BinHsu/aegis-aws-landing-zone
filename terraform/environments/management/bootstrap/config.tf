# -----------------------------------------------------------------------------
# Configuration Contract — ADR-004
# -----------------------------------------------------------------------------
# Every environment reads the same YAML config. No hardcoded account IDs,
# regions, or emails anywhere in Terraform code.
# -----------------------------------------------------------------------------

locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  # Convenience aliases used across this environment
  account_id   = local.config.accounts.management.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]
  tags = merge(local.config.tags, {
    Environment = "management"
  })
}
