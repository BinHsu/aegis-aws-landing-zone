# Single provider — IPAM's regional pools are created through the default
# provider with `locale = <region>`. IPAM is a centrally-scoped service: the
# management plane lives in one region, and individual pools carry their own
# locale. No per-region provider alias is needed.
provider "aws" {
  region = local.primary_region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}
