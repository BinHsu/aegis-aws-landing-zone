# -----------------------------------------------------------------------------
# cert-manager — Helm install (per-cluster)
# -----------------------------------------------------------------------------
# Installed in the platform layer (not workloads) for the same reason as
# Kyverno: the TF-managed ClusterIssuer in cert-manager-clusterissuer.tf
# requires synchronous CRD availability (Certificate + ClusterIssuer CRDs),
# which only helm_release (wait = true) guarantees. See Incident 26 for the
# precedent.
#
# Consumed by aegis-core per ADR-0031 (mTLS without service mesh):
#   - aegis-core creates Certificate CRs per workload (gateway, engine)
#   - cert-manager generates K8s Secrets with cert + key + chain
#   - aegis-core workloads mount the Secrets and reload on rotation
#
# ClusterIssuer backend: self-signed CA (bootstrap chain in the sibling file).
# Path to AWS Private CA is a future ClusterIssuer backend swap, no app-code
# change — aegis-core ADR-0031 §"Migration" documents the swap.
#
# CRDs are installed by the chart (installCRDs=true) rather than by a
# separate ArgoCD-managed CRD Application, keeping the layer self-contained.
# -----------------------------------------------------------------------------

resource "helm_release" "cert_manager" {
  provider = helm.this

  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.16.2"

  values = [
    yamlencode({
      installCRDs = true

      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { memory = "128Mi" }
      }

      webhook = {
        resources = {
          requests = { cpu = "25m", memory = "32Mi" }
          limits   = { memory = "64Mi" }
        }
      }

      cainjector = {
        resources = {
          requests = { cpu = "25m", memory = "64Mi" }
          limits   = { memory = "128Mi" }
        }
      }

      # Emit Prometheus metrics via the ServiceMonitor CRD. Auto-discovered
      # by the platform Prometheus (wide-open selectors per ADR-015).
      prometheus = {
        enabled = true
        servicemonitor = {
          enabled = true
        }
      }
    }),
  ]

  depends_on = [
    aws_eks_cluster.main,
    helm_release.karpenter,
    kubectl_manifest.aegis_cluster_admin_binding,
  ]
}
