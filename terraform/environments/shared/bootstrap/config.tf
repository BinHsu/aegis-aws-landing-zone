# -----------------------------------------------------------------------------
# Configuration Contract — ADR-004
# -----------------------------------------------------------------------------

locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id     = local.config.accounts.shared.id
  org_name       = local.config.organization.name
  org_id         = local.config.organization.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]

  bucket_name = "${local.org_name}-terraform-state-${local.account_id}"

  # Accounts whose CI (`gh-tf-*`) roles write Terraform state. Each account's
  # state lives under a `<account-name>/` key prefix in the shared state bucket
  # (e.g. `staging/bootstrap/terraform.tfstate`); the map keys match those
  # prefixes. Empty ids (an un-vended account in a fork's config) are excluded
  # so the bucket policy never emits a statement with a malformed principal ARN.
  # Consumed by the per-account state-isolation statements in main.tf (#314).
  ci_state_accounts = { for name, acct in local.config.accounts : name => acct.id if acct.id != "" }

  tags = merge(local.config.tags, {
    Environment = "shared"
  })
}

check "exactly_one_primary_region" {
  assert {
    condition     = length([for r in local.config.regions : r if r.role == "primary"]) == 1
    error_message = "config/landing-zone.yaml regions[] must have exactly one entry with role: primary."
  }
}
