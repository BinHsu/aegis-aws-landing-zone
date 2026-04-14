# -----------------------------------------------------------------------------
# ClusterRoleBinding — aegis-cluster-admins -> cluster-admin
# -----------------------------------------------------------------------------
# Why this exists: EKS Access Entry forbids kubernetes_groups starting with
# the reserved `system:` prefix (see Incident 21). We can't map CI / operator
# principals to `system:masters` directly. Instead we map them to a custom
# group `aegis-cluster-admins` (access-entries.tf) and bind that group to the
# built-in `cluster-admin` ClusterRole here.
#
# Bootstrap chicken-and-egg:
#   - CI role's Access Entry maps it to `aegis-cluster-admins`. But the
#     group has no rights until this binding exists.
#   - `aws_eks_access_policy_association.ci_cluster_admin` gives the role
#     AmazonEKSClusterAdminPolicy which IS sufficient to create a
#     ClusterRoleBinding.
#   - So bootstrap flow: cluster + access-entry + policy-association ready
#     first, then Terraform applies this manifest using CI's policy-granted
#     rights. After this, group membership provides full cluster-admin
#     including the CRD-delete coverage that AmazonEKSClusterAdminPolicy
#     alone misses (Incident 18).
#
# On destroy: every helm_release and kubectl_manifest that needs true
# cluster-admin for CRD teardown must `depends_on` this binding, so
# Terraform destroys them FIRST (binding still live), then binding, then
# access-entry/policy-association. If this dep is missing, destroy races
# and CRD delete can fail mid-flight (the scenario Incident 18's original
# fix attempted to solve).
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "aegis_cluster_admin_binding" {
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata = {
      name = "aegis-cluster-admins"
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/part-of"    = "aegis-landing-zone"
      }
    }
    subjects = [{
      kind     = "Group"
      name     = "aegis-cluster-admins"
      apiGroup = "rbac.authorization.k8s.io"
    }]
    roleRef = {
      kind     = "ClusterRole"
      name     = "cluster-admin"
      apiGroup = "rbac.authorization.k8s.io"
    }
  })

  depends_on = [
    # Must exist before the binding can be applied; policy association
    # provides the bootstrap permissions.
    aws_eks_access_policy_association.ci_cluster_admin,
    # Operator SSO role may not be assignable yet (management/bootstrap
    # race — see check block in access-entries.tf); this dep is advisory,
    # not hard-blocking.
  ]
}
