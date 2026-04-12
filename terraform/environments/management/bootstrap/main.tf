# -----------------------------------------------------------------------------
# Management Account Bootstrap
# -----------------------------------------------------------------------------
# This is the Terraservices "bootstrap" layer for the management account.
# It establishes the account-level baseline that all other layers depend on.
#
# What lives here:
#   - Account alias
#   - (Future) GitHub OIDC identity provider — after aegis-shared state bucket
#   - (Future) CI/CD IAM roles — after GitHub Actions workflows
#
# What does NOT live here (per ADR-001 management account boundary):
#   - No workloads, no application resources
#   - No state bucket (lives in aegis-shared per ADR-003)
# -----------------------------------------------------------------------------

resource "aws_iam_account_alias" "this" {
  account_alias = "aegis-management"
}

# Data source to verify we are operating in the correct account
data "aws_caller_identity" "current" {}

data "aws_organizations_organization" "current" {}

check "config_account_id_not_empty" {
  assert {
    condition     = local.account_id != ""
    error_message = "accounts.management.id in landing-zone.yaml is empty. Fill in the 12-digit account ID before running Terraform."
  }
}
