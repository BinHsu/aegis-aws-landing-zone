# -----------------------------------------------------------------------------
# Security Hub — org configuration + FSBP standard (Epic #302 Stage S4, #306)
# -----------------------------------------------------------------------------
# Runs in the `security` account, the org delegated administrator for Security
# Hub since S2 (#304, PR #311). Shape per issue #306 / epic #302 decision D4:
#
#   1. Security Hub enabled in this account, default standards suppressed.
#   2. Finding aggregator with home region = primary (created here, in the
#      primary-region provider) and the remaining governed region(s) linked.
#   3. Exactly ONE standards subscription: FSBP. No CIS, no PCI.
#   4. Org configuration LOCAL: auto-enable Security Hub for accounts that
#      JOIN the org later, with `auto_enable_standards = "NONE"` so no
#      default standard sneaks in with them.
#
# SCOPE NOTE — existing member accounts: with LOCAL configuration,
# `auto_enable = true` covers only accounts added to the org AFTER this
# apply. The six existing member accounts are NOT enrolled in Security Hub by
# this layer (that would need per-account `aws_securityhub_member` resources
# or CENTRAL configuration policies — deliberately out of #306's resource
# list, and the cheap end of the cost envelope). FSBP checks therefore run in
# THIS account only for now. Flagged as an open decision in ADR-023 §OQ-1.
#
# REGION NOTE on the aggregator: issue #306 says `SPECIFIED_REGIONS` =
# primary region. The AWS API defines `specified_regions` as the LINKED
# regions and rejects the home region in that list — the home region is
# implicitly where the aggregator is created (this provider = primary). The
# issue's intent (home/aggregation region = primary) is satisfied by creating
# the aggregator here; `specified_regions` carries the remaining governed
# region(s) from config (currently eu-west-1, where Security Hub is not
# enabled, so nothing flows and nothing bills — aggregation itself is free).
#
# COST: FSBP security checks bill per check per account per region:
# $0.0010/check (first 100k/account/region/month) in eu-central-1. 30-day
# free trial per account. See docs/finops.md "Detective baseline" + ADR-023.
# -----------------------------------------------------------------------------

resource "aws_securityhub_account" "this" {
  count = var.detective_enabled ? 1 : 0

  # FSBP is subscribed explicitly below; suppress the default-standards
  # bundle (which would also pull in CIS) — epic #302 decision D4.
  enable_default_standards = false

  # New FSBP controls added by AWS are picked up automatically — the frugal
  # lever is the standard count (one), not a frozen control list.
  auto_enable_controls = true
}

resource "aws_securityhub_finding_aggregator" "primary" {
  count = var.detective_enabled ? 1 : 0

  linking_mode      = "SPECIFIED_REGIONS"
  specified_regions = local.non_primary_regions

  depends_on = [aws_securityhub_account.this]
}

resource "aws_securityhub_standards_subscription" "fsbp" {
  count = var.detective_enabled ? 1 : 0

  standards_arn = "arn:aws:securityhub:${local.primary_region}::standards/aws-foundational-security-best-practices/v/1.0.0"

  depends_on = [aws_securityhub_account.this]
}

resource "aws_securityhub_organization_configuration" "org" {
  count = var.detective_enabled ? 1 : 0

  # LOCAL configuration (the resource default): each account manages its own
  # standards; the org only auto-enables Security Hub itself for NEW accounts.
  auto_enable           = true
  auto_enable_standards = "NONE"

  # Serialize behind the aggregator + subscription — org-configuration and
  # standards calls against a freshly enabled hub race otherwise.
  depends_on = [
    aws_securityhub_finding_aggregator.primary,
    aws_securityhub_standards_subscription.fsbp,
  ]
}
