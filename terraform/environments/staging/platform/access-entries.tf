# -----------------------------------------------------------------------------
# Access Entries — who gets Kubernetes cluster-admin
# -----------------------------------------------------------------------------
# This project uses EKS Access Entries (not the legacy aws-auth ConfigMap)
# per ADR-013 "Operator access". Access Entries map AWS IAM principals
# directly to Kubernetes RBAC via AWS-managed cluster policies.
#
# IMPORTANT: Access Policy ARNs have their OWN namespace, separate from
# IAM Managed Policy ARNs. The correct format is:
#
#   arn:aws:eks::aws:cluster-access-policy/<PolicyName>
#
# NOT `arn:aws:iam::aws:policy/<PolicyName>`. Passing an IAM ARN to
# aws_eks_access_policy_association fails at apply with
# `InvalidParameterException: The policyArn parameter format is not valid`.
# See Incident 11 in docs/incidents.md for the discovery story.
#
# Two principals need cluster-admin in staging:
#
#   1. The GitHub Actions CI role — so that the Helm and Kubernetes
#      Terraform providers in subsequent PRs (Karpenter, LB Controller,
#      ArgoCD) can `apply` in-cluster resources.
#
#   2. The operator's PlatformAdmin SSO role — so that the human operator
#      can `kubectl` against the cluster after `aws sso login`.
#
# The SSO role is looked up by name pattern. Its existence in the staging
# account depends on the corresponding permission-set assignment in
# management/bootstrap/sso-assignments.tf having applied first. Since that
# layer runs in terraform-apply-baseline.yml and this layer runs in
# terraform-apply-workload.yml (which the operator dispatches manually
# after the baseline is green), the ordering is enforced by the workflow
# split — no explicit cross-state dependency is needed.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# GitHub Actions CI role — grant cluster-admin so post-cluster PRs
# (Karpenter, LB Controller, ArgoCD) can apply via the kubernetes/helm
# Terraform providers.
# -----------------------------------------------------------------------------
locals {
  ci_role_arn = "arn:aws:iam::${local.account_id}:role/github-actions-terraform"
}

resource "aws_eks_access_entry" "ci" {
  cluster_name      = aws_eks_cluster.main.name
  principal_arn     = local.ci_role_arn
  type              = "STANDARD"
  kubernetes_groups = []
}

resource "aws_eks_access_policy_association" "ci_cluster_admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = local.ci_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.ci]
}

# -----------------------------------------------------------------------------
# Operator — PlatformAdmin SSO role → cluster-admin
# -----------------------------------------------------------------------------
# AWS creates a reserved role `AWSReservedSSO_PlatformAdmin_<hash>` in this
# account whenever an Identity Center permission set is assigned to it. The
# hash suffix is deterministic per (permission set, account) but not
# predictable ahead of time, so we discover it via data source.
#
# Prerequisite: management/bootstrap/sso-assignments.tf must have applied
# first (assigns the permission set to this account, which causes the role
# to be created). If that has not happened, the data source returns empty
# and the check block below fails with a clear error.
# -----------------------------------------------------------------------------

data "aws_iam_roles" "sso_platform_admin" {
  name_regex  = "^AWSReservedSSO_PlatformAdmin_.*"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

locals {
  platform_admin_role_arn = one(tolist(data.aws_iam_roles.sso_platform_admin.arns))
}

check "sso_platform_admin_role_exists" {
  assert {
    condition     = local.platform_admin_role_arn != null
    error_message = "The AWSReservedSSO_PlatformAdmin_* role does not exist in this account. Ensure management/bootstrap has applied the aws_ssoadmin_account_assignment for staging (see management/bootstrap/sso-assignments.tf). If it has just applied, allow ~30-60 seconds for SSO to create the reserved role in this account, then re-run."
  }
}

resource "aws_eks_access_entry" "operator" {
  count = local.platform_admin_role_arn == null ? 0 : 1

  cluster_name      = aws_eks_cluster.main.name
  principal_arn     = local.platform_admin_role_arn
  type              = "STANDARD"
  kubernetes_groups = []
}

resource "aws_eks_access_policy_association" "operator_cluster_admin" {
  count = local.platform_admin_role_arn == null ? 0 : 1

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = local.platform_admin_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.operator]
}
