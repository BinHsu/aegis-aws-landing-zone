# -----------------------------------------------------------------------------
# Provider aliases — slot pattern, K=2 per ADR-018 §3 (amended 2026-04-19)
# -----------------------------------------------------------------------------
# Two role-based aliases, plus a default provider for any incidental data
# sources. Alias *labels* are static HCL identifiers; region values come
# from config. No region literals appear in this file.
#
# Slot pattern: slots are pre-declared for all possible positions in
# local.eks_regions (K=2: primary + one slave). When length(eks_regions)==1,
# the slave_1 provider still exists but no module invocation uses it
# (count=0). The slot's region argument falls back to primary to satisfy
# Terraform's "every provider needs a region" requirement.
#
# Growing beyond K=2 requires adding a new alias block + a new module
# invocation + an ADR amendment. Truly dynamic N would require migrating
# to a generation-script pattern — that is a separate ADR. See ADR-018 §3
# "Scaling boundary".
# -----------------------------------------------------------------------------

provider "aws" {
  region = local.primary_region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}

provider "aws" {
  alias  = "primary"
  region = local.primary_region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}

provider "aws" {
  alias = "slave_1"
  # try() fallback when eks_regions is length 1: the slot is declared but
  # unused (module cluster_slave_1 has count=0). The region still has to
  # be a valid value that the AWS SDK accepts; reusing primary is the
  # zero-footprint choice.
  region = try(local.slave_regions[0].region, local.primary_region)

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}
