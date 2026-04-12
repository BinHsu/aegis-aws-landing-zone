provider "aws" {
  region = local.primary_region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}
