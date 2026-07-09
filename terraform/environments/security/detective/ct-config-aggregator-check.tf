# -----------------------------------------------------------------------------
# Control Tower Config aggregator — read-only assertion (Epic #302 S4, #306)
# -----------------------------------------------------------------------------
# Epic #302's key verified fact: the AWS Config aggregator in this (audit/
# security) account is PROVIDED BY CONTROL TOWER. This layer must never create
# or own one — it only asserts the CT-managed aggregator still exists, so a
# future "cleanup" that deletes it is caught at the next plan instead of
# silently blinding org-wide Config aggregation.
#
# WHY an `external` data source: the AWS provider (6.x) has no
# `data "aws_config_configuration_aggregator"` (verified 2026-07-09 — the
# provider docs path 404s). The smallest read-only probe is one
# `configservice describe-configuration-aggregators` call, wrapped in a script
# that ALWAYS exits 0 and reports its outcome as data, so a permissions gap
# degrades to a failed check (a plan/apply WARNING per Terraform check-block
# semantics) — never a hard failure.
#
# KNOWN CI LIMITATION (documented, not hidden): the CI roles are capped by the
# org-uniform permissions boundary (ADR-020), whose Allow ceiling does not yet
# include the `config` namespace. Until `config:Describe*` is added to the
# boundary (a 7-file, all-accounts-uniform change that touches
# management/bootstrap — deferred to keep this PR out of the parallel
# management-area workstreams), CI plans report this check as FAILED-WARNING
# with an AccessDenied detail. The #306 validation criterion ("check passes
# against the existing CT aggregator") is asserted by running
# `terraform plan` locally under operator SSO credentials. See ADR-023.
# -----------------------------------------------------------------------------

check "ct_config_aggregator_exists" {
  data "external" "ct_config_aggregator" {
    program = [
      "bash",
      "${path.module}/scripts/check-ct-config-aggregator.sh",
      local.primary_region,
    ]
  }

  assert {
    condition = data.external.ct_config_aggregator.result.found == "true"
    error_message = join(" ", [
      "Control-Tower-managed Config aggregator not confirmed in this account",
      "(result: ${data.external.ct_config_aggregator.result.found};",
      "detail: ${data.external.ct_config_aggregator.result.detail}).",
      "If detail says AccessDenied, the caller lacks config:Describe* (CI",
      "boundary gap, ADR-023) — re-run under operator SSO credentials.",
      "If found=false under full credentials, the CT aggregator is GONE:",
      "stop and investigate Control Tower drift before touching this layer.",
    ])
  }
}
