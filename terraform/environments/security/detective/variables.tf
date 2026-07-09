# -----------------------------------------------------------------------------
# Lifecycle toggle — decided by Bin on issues #305/#306 (2026-07-06): the
# detective services are NOT always-on; they ride the platform bring-up /
# teardown lifecycle. This variable is the clean enable/disable switch:
#
#   true  → GuardDuty org auto-enable + Security Hub (FSBP) are created and
#           recurring cost accrues (see docs/finops.md "Detective baseline").
#   false → every billable resource in this layer is destroyed on the next
#           apply; the layer (and its CI wiring) stays in place, code-complete.
#
# CAVEAT on disable: Terraform only destroys what it owns — the delegated-
# admin detector, the org auto-enable configuration, and the Security Hub
# resources in THIS account. Member-account GuardDuty detectors that were
# auto-created by `auto_enable_organization_members = "ALL"` are not in this
# state and keep billing until removed. Run
# scripts/disable-member-detectors.sh (this layer's scripts/ dir) after the
# toggle-off apply to stop member-side cost. See ADR-023.
# -----------------------------------------------------------------------------
variable "detective_enabled" {
  description = "Master lifecycle switch for the detective services (GuardDuty org auto-enable + Security Hub FSBP). false destroys all billable resources in this layer on the next apply while keeping the layer code-complete. Flip via a one-line PR; pair toggle-off with scripts/disable-member-detectors.sh to stop member-account GuardDuty cost."
  type        = bool
  default     = true
}
