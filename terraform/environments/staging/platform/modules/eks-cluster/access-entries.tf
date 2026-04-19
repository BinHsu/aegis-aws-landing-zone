# -----------------------------------------------------------------------------
# Access Entries — who gets Kubernetes cluster-admin (per-cluster)
# -----------------------------------------------------------------------------
# See pre-refactor top-level access-entries.tf for full commentary.
# Two principals get cluster-admin:
#   1. GitHub Actions CI role (var.ci_role_arn) — so Helm / Kubernetes
#      providers in this module apply cluster resources
#   2. Operator PlatformAdmin SSO role — looked up by name pattern from IAM
#
# Both are AWS-account-global principals shared across clusters, so both
# module invocations end up creating access entries for the same role ARNs,
# but the aws_eks_access_entry resources are cluster-scoped — no conflict.
# -----------------------------------------------------------------------------

resource "aws_eks_access_entry" "ci" {
  provider = aws.this

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.ci_role_arn
  type          = "STANDARD"

  # Custom group — EKS Access Entry rejects system:* prefixes (Incident 21).
  # Cluster-admin bootstrapping comes from the policy association below; the
  # group is bound to cluster-admin via the ClusterRoleBinding in
  # cluster-role-binding.tf for symmetric CRD create/delete rights (Incident 18).
  kubernetes_groups = ["${var.organization_name}-cluster-admins"]
}

resource "aws_eks_access_policy_association" "ci_cluster_admin" {
  provider = aws.this

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.ci_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.ci]
}

# -----------------------------------------------------------------------------
# Operator — PlatformAdmin SSO role → cluster-admin
# -----------------------------------------------------------------------------
# IAM is account-global; the data source works regardless of the aws.this
# provider's region. The SSO-reserved role exists only after management/
# bootstrap's permission-set assignment has propagated.
# -----------------------------------------------------------------------------

data "aws_iam_roles" "sso_platform_admin" {
  provider = aws.this

  name_regex  = "^AWSReservedSSO_PlatformAdmin_.*"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

locals {
  platform_admin_role_arn = one(tolist(data.aws_iam_roles.sso_platform_admin.arns))
}

check "sso_platform_admin_role_exists" {
  assert {
    condition     = local.platform_admin_role_arn != null
    error_message = "The AWSReservedSSO_PlatformAdmin_* role does not exist in account ${var.account_id}. Ensure management/bootstrap has applied the aws_ssoadmin_account_assignment for staging (see management/bootstrap/sso-assignments.tf). If it has just applied, allow ~30-60 seconds for SSO to create the reserved role, then re-run."
  }
}

resource "aws_eks_access_entry" "operator" {
  provider = aws.this

  count = local.platform_admin_role_arn == null ? 0 : 1

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = local.platform_admin_role_arn
  type          = "STANDARD"

  kubernetes_groups = ["${var.organization_name}-cluster-admins"]
}

resource "aws_eks_access_policy_association" "operator_cluster_admin" {
  provider = aws.this

  count = local.platform_admin_role_arn == null ? 0 : 1

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = local.platform_admin_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.operator]
}
