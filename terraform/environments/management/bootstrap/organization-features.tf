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
