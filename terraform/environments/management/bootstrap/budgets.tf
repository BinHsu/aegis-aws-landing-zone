# -----------------------------------------------------------------------------
# Cost guardrails — AWS Budgets as IaC (ADR-019)
# -----------------------------------------------------------------------------
# The org-wide budgets `aegis-daily-usd10` and `aegis-monthly-usd30` were
# created in the console during runbook 001 Part 3.5 — before any Terraform
# exists in a fresh account — and were the only guardrail that fired in the
# 2026-06-06 cost incident. ADR-019 brings them under Terraform.
#
# The `import` blocks adopt the live console budgets on the first apply after
# this file lands (no collision, no recreate). They assume runbook 001 §3.5
# already ran — which it has on any account bootstrapped by this repo, because
# §3.5 precedes the first `terraform apply`. A fork that skipped §3.5 must
# either create the two budgets first or delete the import blocks and let
# Terraform create them. Once the budgets are in state the import blocks are
# no-ops and can be removed in a later cleanup.
#
# These budgets live in the management (payer) account, so they see the
# consolidated org-wide spend. The logarchive member budget also lives here —
# scoped by a LinkedAccount cost filter — because the logarchive account is
# Control-Tower-managed and has no Terraform environment of its own (see
# ADR-019 Consequences).
# -----------------------------------------------------------------------------

locals {
  # Per-member-account monthly ceiling (USD). Optional config key; defaults
  # to 10 — the same shape as the org daily tripwire.
  member_budget_usd = tostring(try(local.config.budget.member_monthly_usd, 10))
}

import {
  to = aws_budgets_budget.org_daily
  id = "${local.account_id}:aegis-daily-usd10"
}

import {
  to = aws_budgets_budget.org_monthly
  id = "${local.account_id}:aegis-monthly-usd30"
}

resource "aws_budgets_budget" "org_daily" {
  name         = "aegis-daily-usd10"
  budget_type  = "COST"
  limit_amount = tostring(local.config.budget.daily_usd)
  limit_unit   = "USD"
  time_unit    = "DAILY"

  # Runbook 001 §3.5.3: a single 80%-of-actual alert. The daily budget is the
  # fast circuit breaker — a day past this threshold means a runaway resource.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = local.config.budget.alert_emails
  }
}

resource "aws_budgets_budget" "org_monthly" {
  name         = "aegis-monthly-usd30"
  budget_type  = "COST"
  limit_amount = tostring(local.config.budget.monthly_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Runbook 001 §3.5.2 created this from the console "monthly cost budget"
  # template and did not pin thresholds; the code standardizes on 80% + 100%
  # of actual. The first apply after import reconciles the console template's
  # notification set to these two (in-place update, not a recreate).
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

# Per-account monthly budget for aegis-logarchive. New resource (the account
# had none — one of the gaps the 2026-06-06 postmortem flagged). Unlike the
# org budgets above it is filtered to a single linked account.
resource "aws_budgets_budget" "member_monthly_logarchive" {
  name         = "aegis-logarchive-monthly-usd${local.member_budget_usd}"
  budget_type  = "COST"
  limit_amount = local.member_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "LinkedAccount"
    values = [local.config.accounts.logarchive.id]
  }

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
