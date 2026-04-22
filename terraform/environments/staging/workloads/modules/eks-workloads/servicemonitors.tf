# -----------------------------------------------------------------------------
# Explicit ServiceMonitor CRDs — cert-manager + argo-rollouts (ADR-022 PR-3)
# -----------------------------------------------------------------------------
# Both charts ship with `serviceMonitor.enabled = false` (PR #119 decision
# to avoid the async-CRD-race pattern described in Incident 26 / 28). Under
# ADR-015 (kube-prometheus-stack), the workloads-layer follow-up to add
# explicit ServiceMonitors was deferred. Under ADR-022 (Alloy + prometheus-
# operator-crds in staging/platform), the follow-up lands here — CRDs are
# now guaranteed present before the workloads layer applies, so there is no
# race.
#
# ServiceMonitors live in `monitoring` namespace (co-located with Alloy +
# prometheus-operator-crds + kube-state-metrics) even though the target
# Services are in other namespaces (cert-manager, argo-rollouts). This is
# the standard pattern kube-prometheus-stack used — scrape-side resources
# cluster in one namespace, `namespaceSelector` crosses to target ns.
# Alloy's `prometheus.operator.servicemonitors` component discovers these
# via wide-open selectors (no namespace / label filter).
#
# Port name values are chart-version-specific:
#
#   cert-manager 1.16.2 ships Service with port name
#   `tcp-prometheus-servicemonitor` on 9402 (from chart templates/service.yaml).
#
#   argo-rollouts 2.37.7 ships Service `argo-rollouts-metrics` with port
#   `metrics` on 8090 (from chart templates/controller/service.yaml).
#
# If a chart version bump rename the port, update here — Alloy's scrape will
# silently fail to discover targets until the names match.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "servicemonitor_cert_manager" {
  provider = kubectl.this

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "cert-manager"
      namespace = "monitoring"
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/part-of"    = "platform"
      }
    }
    spec = {
      selector = {
        matchLabels = {
          "app.kubernetes.io/name"      = "cert-manager"
          "app.kubernetes.io/component" = "controller"
        }
      }
      namespaceSelector = {
        matchNames = ["cert-manager"]
      }
      endpoints = [{
        port     = "tcp-prometheus-servicemonitor"
        path     = "/metrics"
        interval = "30s"
      }]
    }
  })
}

resource "kubectl_manifest" "servicemonitor_argo_rollouts" {
  provider = kubectl.this

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "argo-rollouts"
      namespace = "monitoring"
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/part-of"    = "platform"
      }
    }
    spec = {
      selector = {
        matchLabels = {
          "app.kubernetes.io/name" = "argo-rollouts"
        }
      }
      namespaceSelector = {
        matchNames = ["argo-rollouts"]
      }
      endpoints = [{
        port     = "metrics"
        path     = "/metrics"
        interval = "30s"
      }]
    }
  })
}
