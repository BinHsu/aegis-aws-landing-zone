provider "aws" {
  region = local.primary_region

  default_tags {
    tags = local.tags
  }

  # Safety: prevent accidental operations against the wrong account
  allowed_account_ids = [local.account_id]
}
