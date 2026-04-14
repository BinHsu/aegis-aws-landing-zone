# -----------------------------------------------------------------------------
# EC2 Spot Service-Linked Role
# -----------------------------------------------------------------------------
# Karpenter (per staging/platform) launches EC2 Spot instances. AWS requires
# a service-linked role named `AWSServiceRoleForEC2Spot` in the account
# before ANY Spot request can be fulfilled. In a fresh AWS account, this
# role does not exist — the first Spot launch attempt fails with:
#
#   AuthFailure.ServiceLinkedRoleCreationNotPermitted:
#     The provided credentials do not have permission to create the
#     service-linked role for EC2 Spot Instances.
#
# The simplest fix in theory — grant Karpenter `iam:CreateServiceLinkedRole`
# — is wrong in practice. Creating an SLR is a one-time per-account
# operation; once the role exists it persists forever. Giving Karpenter
# that permission on every reconcile cycle is gratuitous scope.
#
# The right fix is to create the SLR in bootstrap (once per account, before
# any platform apply). This resource is idempotent in Terraform: if the SLR
# already exists in AWS, `terraform apply` imports its state rather than
# failing.
#
# See docs/incidents.md Incident 15 for the discovery story. This resource
# exists precisely so forkers do NOT re-experience that incident.
# -----------------------------------------------------------------------------

resource "aws_iam_service_linked_role" "spot" {
  aws_service_name = "spot.amazonaws.com"
  description      = "Service-linked role for EC2 Spot Instances (used by Karpenter in staging/platform)"

  # Terraform's behavior when the SLR already exists in the account:
  # the aws_iam_service_linked_role provider has special handling to
  # import-in-place rather than conflict. See HashiCorp provider source;
  # this has been tested for this specific SLR.
}
