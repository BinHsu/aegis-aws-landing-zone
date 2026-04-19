# -----------------------------------------------------------------------------
# ClusterRoleBinding — ${org}-cluster-admins → built-in cluster-admin
# -----------------------------------------------------------------------------
# See pre-refactor top-level cluster-role-binding.tf for the bootstrap
# chicken-and-egg + destroy-ordering rationale (Incidents 18, 21).
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "aegis_cluster_admin_binding" {
  provider = kubectl.this

  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata = {
      name = "${var.organization_name}-cluster-admins"
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/part-of"    = "${var.organization_name}-landing-zone"
      }
    }
    subjects = [{
      kind     = "Group"
      name     = "${var.organization_name}-cluster-admins"
      apiGroup = "rbac.authorization.k8s.io"
    }]
    roleRef = {
      kind     = "ClusterRole"
      name     = "cluster-admin"
      apiGroup = "rbac.authorization.k8s.io"
    }
  })

  depends_on = [
    aws_eks_access_policy_association.ci_cluster_admin,
  ]
}
