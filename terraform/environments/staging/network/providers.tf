# -----------------------------------------------------------------------------
# Provider — single region per apply (ADR-032 external orchestration)
# -----------------------------------------------------------------------------
# This layer handles exactly one region per `terraform apply`. The region is
# injected by the orchestrator (Makefile / CI matrix) as `TF_VAR_region`.
# There are no provider aliases and no slot pattern — the multi-region loop
# lives outside Terraform. See ADR-032.
#
# No region literal appears here: `region` is driven from `var.region`.
# -----------------------------------------------------------------------------

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}
