locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id        = local.config.accounts.shared.id
  org_arn           = "arn:aws:organizations::${local.config.accounts.management.id}:organization/${local.config.organization.id}"
  primary_region    = [for r in local.config.regions : r.name if r.role == "primary"][0]
  dr_region         = [for r in local.config.regions : r.name if r.role == "dr"][0]
  operating_regions = [for r in local.config.regions : r.name]

  top_cidr   = local.config.ipam.top_cidr
  pool_cidrs = local.config.ipam.pools # map: region → { cidr = "..." }

  tags = merge(local.config.tags, {
    Environment = "shared"
    Component   = "ipam"
  })
}

check "exactly_one_primary_region" {
  assert {
    condition     = length([for r in local.config.regions : r if r.role == "primary"]) == 1
    error_message = "config/landing-zone.yaml regions[] must have exactly one entry with role: primary."
  }
}
