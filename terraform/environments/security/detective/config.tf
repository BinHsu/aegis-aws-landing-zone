locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id     = local.config.accounts.security.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]

  # Governed regions other than the primary — the linked-region set for the
  # Security Hub finding aggregator (the home region itself must not appear in
  # `specified_regions`; see securityhub.tf).
  non_primary_regions = [for r in local.config.regions : r.name if r.role != "primary"]

  tags = merge(local.config.tags, {
    Environment = "security"
  })
}

check "exactly_one_primary_region" {
  assert {
    condition     = length([for r in local.config.regions : r if r.role == "primary"]) == 1
    error_message = "config/landing-zone.yaml regions[] must have exactly one entry with role: primary."
  }
}

check "config_account_id_not_empty" {
  assert {
    condition     = local.account_id != ""
    error_message = "accounts.security.id in landing-zone.yaml is empty. Create the account first (Runbook 001 Part 9)."
  }
}
