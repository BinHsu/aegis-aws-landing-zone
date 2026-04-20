# -----------------------------------------------------------------------------
# Provider — single primary region
# -----------------------------------------------------------------------------
# FIS experiments are regional. The demo experiment targets primary-region
# EKS worker nodes (attacking Region A to validate the Region B failover
# path). No secondary provider needed: CloudWatch alarms used as stop
# conditions must live in the SAME region as the experiment template, so
# the alarm is also primary-region. Cross-region alarms would require
# metric streams — ADR-020 §Alternatives Considered §"Cross-region stop
# condition" documents why we accept the single-region simplification.
# -----------------------------------------------------------------------------

provider "aws" {
  region = local.primary_region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}
