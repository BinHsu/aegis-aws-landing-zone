# -----------------------------------------------------------------------------
# Detective Services — Delegated Admin Registration (Epic #302 Stage S2)
# -----------------------------------------------------------------------------
# Registers the `security` account as the org-wide delegated administrator for
# GuardDuty and Security Hub. This is management-side delegation ONLY — per
# epic #302 decision D5, the detective services themselves (GuardDuty auto-
# enable for member accounts, Security Hub standards subscriptions) are owned
# by a separate `security/detective` Terraform layer (Stages S3/S4), not this
# account-fabric baseline.
#
# Unlike the generic `aws_organizations_delegated_administrator` resource used
# for IPAM above, GuardDuty and Security Hub each have their OWN dedicated
# Terraform resource / AWS API (`EnableOrganizationAdminAccount`) that performs
# the delegated-admin registration for that service specifically. Functionally
# analogous two-step prerequisite as the IPAM pattern above:
#
#   1. Enable AWS Organizations trusted-service access for the service
#      (one-time, manual CLI — see PREREQUISITE note on each resource below).
#   2. Register the delegated admin account (this Terraform).
#
# Precheck (2026-07-06): both `list-organization-admin-accounts` calls
# (GuardDuty and Security Hub) returned empty in this org — these are pure
# `create` resources, not imports. `security` (763879260536) is already a
# delegated administrator for other Control-Tower-managed services, so the
# org-level trust relationship exists, but the per-service service-access
# enablement below is independent per service and must still be done once.
# -----------------------------------------------------------------------------

# PREREQUISITE (one-time, manual CLI, run under aegis-management-admin before
# the first apply of this resource):
#
#   aws organizations enable-aws-service-access \
#     --service-principal guardduty.amazonaws.com
#
# Without this, apply fails with:
# "AccessDeniedException: ... you must enable service access before you can
# delegate an administrator for this service" (same failure shape as the IPAM
# precedent above — see docs/runbooks/001-bootstrap-aws-account.md).
resource "aws_guardduty_organization_admin_account" "security" {
  admin_account_id = local.config.accounts.security.id
}

# PREREQUISITE (one-time, manual CLI, run under aegis-management-admin before
# the first apply of this resource):
#
#   aws organizations enable-aws-service-access \
#     --service-principal securityhub.amazonaws.com
#
# Precheck confirmed Control Tower did NOT pre-set a Security Hub delegated
# admin in this org (list-organization-admin-accounts returned empty) — this
# is a create, not an import, despite Security Hub sometimes arriving
# pre-delegated in other Control Tower landing zones.
resource "aws_securityhub_organization_admin_account" "security" {
  admin_account_id = local.config.accounts.security.id
}
