locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id     = local.config.accounts.management.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]
  tags = merge(local.config.tags, {
    Environment = "management"
  })
}

check "exactly_one_primary_region" {
  assert {
    condition     = length([for r in local.config.regions : r if r.role == "primary"]) == 1
    error_message = "config/landing-zone.yaml regions[] must have exactly one entry with role: primary."
  }
}
