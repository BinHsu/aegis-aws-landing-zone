# -----------------------------------------------------------------------------
# kube-state-metrics — K8s object state exporter (ADR-022 Layer 1 deps)
# -----------------------------------------------------------------------------
# KSM emits `kube_*` metrics (kube_pod_status_phase, kube_node_status_condition,
# kube_deployment_status_replicas, ...) that platform alerts — and the service-
# level SLO alerts aegis-core ships — both depend on.
#
# Was implicitly bundled inside kube-prometheus-stack (ADR-015). With the
# reversal to Alloy + prometheus-operator-crds (ADR-022), KSM must be
# installed explicitly: prometheus-operator-crds is CRDs-only and does not
# ship KSM. Without this release, `kube_node_status_condition` would stop
# emitting and Incident 29's NodeNotReady alert goes permanently silent.
#
# Self-scraping: chart ships a ServiceMonitor (prometheus.monitor.enabled)
# that Alloy picks up via its prometheus.operator.servicemonitors component
# — no explicit ServiceMonitor manifest needed here.
# -----------------------------------------------------------------------------

resource "helm_release" "kube_state_metrics" {
  count = var.observability_enabled ? 1 : 0

  provider = helm.this

  name       = "kube-state-metrics"
  namespace  = "monitoring"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-state-metrics"
  version    = "5.25.1"

  values = [
    yamlencode({
      resources = {
        requests = { cpu = "25m", memory = "64Mi" }
        limits   = { memory = "128Mi" }
      }

      # ServiceMonitor auto-creation — relies on CRDs from
      # prometheus-operator-crds (sibling file). Explicit depends_on on that
      # release ensures CRDs are present before this release's post-install
      # hooks attempt to create the ServiceMonitor.
      prometheus = {
        monitor = {
          enabled = true
        }
      }
    }),
  ]

  depends_on = [
    helm_release.prometheus_operator_crds,
  ]
}
