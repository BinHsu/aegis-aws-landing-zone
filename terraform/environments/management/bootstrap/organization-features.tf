# -----------------------------------------------------------------------------
# AWS Organizations — Trusted Service Access and RAM Sharing
# -----------------------------------------------------------------------------
# These resources enable cross-account sharing capabilities used by other
# layers (notably shared/ipam). They are organization-level features that
# can only be enabled from the management account.
#
# Once enabled, they remain enabled for the lifetime of the organization.
# These resources are essentially "switches" — Terraform owns the on/off
# state but there is nothing to "configure" beyond enablement.
# -----------------------------------------------------------------------------

# Enable RAM (Resource Access Manager) sharing across the organization.
# Required for shared/ipam to share IPAM pools with member accounts.
# Without this, any aws_ram_resource_share targeting the org will fail with
# "OperationNotPermittedException: ... can only be shared within your AWS
# Organization. ... or that onboarding process is still in progress."
resource "aws_ram_sharing_with_organization" "main" {}

# -----------------------------------------------------------------------------
# IPAM — Delegated admin to aegis-shared for cross-account monitoring
# -----------------------------------------------------------------------------
# RAM sharing (above) lets other accounts SEE and USE IPAM pools. But for
# IPAM to automatically MONITOR member accounts (so a VPC created in staging
# can call AllocateIpamPoolCidr against shared's IPAM), the IPAM service
# itself needs org-wide integration.
#
# This is a two-step prerequisite:
#   1. Enable IPAM as a trusted AWS service in the org.
#   2. Delegate IPAM admin to the account that hosts IPAM (aegis-shared per
#      ADR-004 Mode B and ADR-006).
#
# Without this, staging/network apply fails with:
#   "Account <id> is not monitored by IPAM ipam-<id>."
# -----------------------------------------------------------------------------

resource "aws_organizations_delegated_administrator" "ipam" {
  account_id        = local.config.accounts.shared.id
  service_principal = "ipam.amazonaws.com"
}
