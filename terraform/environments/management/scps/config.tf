locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id     = local.config.accounts.management.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]
  tags = merge(local.config.tags, {
    Environment = "management"
  })
}
