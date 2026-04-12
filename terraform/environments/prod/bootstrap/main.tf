resource "aws_iam_account_alias" "this" {
  account_alias = "binhsu-aegis-prod"
}

data "aws_caller_identity" "current" {}

check "config_account_id_not_empty" {
  assert {
    condition     = local.account_id != ""
    error_message = "accounts.prod.id in landing-zone.yaml is empty. Create the account first (Runbook 001 Part 9)."
  }
}
