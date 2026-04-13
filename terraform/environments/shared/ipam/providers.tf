# Primary region provider
provider "aws" {
  region = local.primary_region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}

# DR region provider — needed for the eu-west-1 regional pool
provider "aws" {
  alias  = "eu_west_1"
  region = local.dr_region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}
