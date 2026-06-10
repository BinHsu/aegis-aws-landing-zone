# -----------------------------------------------------------------------------
# Per-account cost guardrail — AWS Budgets as IaC (ADR-019)
# -----------------------------------------------------------------------------
# The deployment account is vended with its budget from day one — the
# 2026-06-06 cost-incident postmortem flagged member accounts without their
# own budget (the org-wide budgets in the management account were the only
# guardrail that fired). This budget tracks this account's own spend; under
# consolidated billing a member-account budget sees only that account's
# usage, so no cost filter is needed.
#
# New resource — nothing to import. Created on the next CI apply of this
# layer via `gh-tf-apply-baseline`.
# -----------------------------------------------------------------------------

locals {
  # Per-member-account monthly ceiling (USD). Optional config key; defaults
  # to 10 — the same shape as the org daily tripwire.
  member_budget_usd = tostring(try(local.config.budget.member_monthly_usd, 10))
}

resource "aws_budgets_budget" "account_monthly" {
  name         = "aegis-deployment-monthly-usd${local.member_budget_usd}"
  budget_type  = "COST"
  limit_amount = local.member_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = local.config.budget.alert_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = local.config.budget.alert_emails
  }
}
