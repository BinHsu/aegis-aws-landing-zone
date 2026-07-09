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
# DEFAULT IS false (decided by Bin, 2026-07-09): this layer lands DORMANT.
# Merging with the default applies only the layer scaffolding — zero billable
# resources. The paid validation window opens later, deliberately, via a
# one-line PR flipping this to true (paired with the ephemeral-EKS validation
# run), not as a side effect of this merge.
#
# CAVEAT on disable (applies to the future enabled→disabled path): Terraform
# only destroys what it owns — the delegated-admin detector, the org
# auto-enable configuration, and the Security Hub resources in THIS account.
# Member-account GuardDuty detectors that were auto-created by
# `auto_enable_organization_members = "ALL"` are not in this state and keep
# billing until removed. Run scripts/disable-member-detectors.sh (this
# layer's scripts/ dir) after the toggle-off apply to stop member-side cost.
# See ADR-023.
# -----------------------------------------------------------------------------
variable "detective_enabled" {
  description = "Master lifecycle switch for the detective services (GuardDuty org auto-enable + Security Hub FSBP). Defaults to false so this layer lands dormant (zero billable resources); flip to true via a one-line PR to open a paid validation window, pairing toggle-off with scripts/disable-member-detectors.sh to stop member-account GuardDuty cost."
  type        = bool
  default     = false
}
