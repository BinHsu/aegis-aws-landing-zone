# -----------------------------------------------------------------------------
# prometheus-operator CRDs — schema only, no controller (ADR-022 Layer 2)
# -----------------------------------------------------------------------------
# Installs ONLY the Prometheus Operator CRDs (ServiceMonitor, PodMonitor,
# PrometheusRule, Probe, AlertmanagerConfig, ...). No Operator controller,
# no Prometheus server, no Alertmanager. Alloy (sibling alloy.tf) consumes
# these CRDs to discover scrape targets and forwards PrometheusRule content
# to Grafana Cloud Mimir ruler for server-side evaluation.
#
# Why helm_release (not ArgoCD Application): the CRDs shipped by this chart
# are the portable contract surface (ADR-023) that TF-managed manifests in
# the staging/workloads/ and staging/observability/ layers reference as
# kubectl_manifest. ArgoCD-synced CRDs would race with those manifests on
# first apply (Incident 28 pattern). helm_release wait=true guarantees CRDs
# exist before downstream TF apply completes.
#
# Chart version pinning: CRDs move slowly — a bump requires a Kubernetes-
# API-compat audit on the downstream manifests (ServiceMonitor / PodMonitor /
# PrometheusRule CRs authored in aegis-core + staging/observability).
# -----------------------------------------------------------------------------

resource "helm_release" "prometheus_operator_crds" {
  count = var.observability_enabled ? 1 : 0

  provider = helm.this

  name             = "prometheus-operator-crds"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "prometheus-operator-crds"
  version          = "16.0.1"

  depends_on = [
    aws_eks_cluster.main,
    helm_release.karpenter,
    kubectl_manifest.aegis_cluster_admin_binding,
  ]
}
