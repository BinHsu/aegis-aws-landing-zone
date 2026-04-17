# -----------------------------------------------------------------------------
# Workload namespace — ADR-017
# -----------------------------------------------------------------------------
# Terraform creates the namespace; ArgoCD deploys workload contents into it.
# Platform-side resources (IRSA roles, NetworkPolicies) depend on the
# namespace existing before any workload syncs.
# -----------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "aegis" {
  metadata {
    name = "aegis"

    labels = {
      "app.kubernetes.io/part-of"    = "aegis"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}
