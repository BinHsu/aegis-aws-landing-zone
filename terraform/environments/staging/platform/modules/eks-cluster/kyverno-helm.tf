# -----------------------------------------------------------------------------
# Kyverno admission controller — Helm install (per-cluster) — ADR-016
# -----------------------------------------------------------------------------
# Kyverno lives in the platform layer (alongside Karpenter / LB Controller /
# ArgoCD), not the workloads layer: admission control is cluster-level infra
# — if Kyverno's webhook is down, pod admission behaviour changes across the
# whole cluster, comparable to LBC/Karpenter failure modes, and unlike
# observability (which degrades visibility but leaves the cluster running).
#
# Install path is helm_release (not an ArgoCD Application) because the
# ClusterPolicy CRDs this chart ships must exist synchronously before the
# platform-authored kubectl_manifest.policy_* resources in kyverno-policies.tf
# can apply. helm_release with wait=true (default) blocks Terraform until the
# release reports Ready, guaranteeing CRD availability; an ArgoCD Application
# wrapped in kubectl_manifest only guarantees the Application object exists in
# etcd, leaving chart sync async → Incident 26 (cold-apply race).
#
# Failure mode: failOpen (chart default) — if Kyverno is down, pods are
# admitted without policy checks. Acceptable for a lab; production would use
# failurePolicy: Fail.
# -----------------------------------------------------------------------------

resource "helm_release" "kyverno" {
  provider = helm.this

  name             = "kyverno"
  namespace        = "kyverno"
  create_namespace = true
  repository       = "https://kyverno.github.io/kyverno"
  chart            = "kyverno"
  version          = "3.4.1"

  values = [
    yamlencode({
      admissionController = {
        replicas = 1
        resources = {
          requests = { cpu = "100m", memory = "200Mi" }
          limits   = { memory = "384Mi" }
        }
      }

      backgroundController = {
        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { memory = "128Mi" }
        }
      }

      cleanupController = {
        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { memory = "128Mi" }
        }
      }

      reportsController = {
        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { memory = "128Mi" }
        }
      }
    }),
  ]

  depends_on = [
    aws_eks_cluster.main,
    helm_release.karpenter,
    # Cluster-admin via group — needed for CRD delete at teardown.
    # See Incident 18 + 21.
    kubectl_manifest.aegis_cluster_admin_binding,
  ]
}
