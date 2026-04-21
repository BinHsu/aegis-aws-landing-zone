# -----------------------------------------------------------------------------
# Platform-owned GrafanaDashboard CRDs (ADR-023 §Domain split)
# -----------------------------------------------------------------------------
# Three dashboards shipped at this PR. All carry label
# `app.kubernetes.io/part-of: platform` so they're visually and
# programmatically distinguishable from aegis-core's service dashboards.
#
# Import strategy — `grafanaCom.id` imports the published dashboard by its
# numeric ID from grafana.com/dashboards. This is the cheapest way to ship
# well-known dashboards (Kubernetes cluster overview, Karpenter, etc.) that
# the community has already maintained; we own only the thin CRD wrapper,
# not the JSON. If a dashboard needs customization, the alternative is
# `spec.json` (inline JSON) or `spec.configMapRef` — out of scope for this
# PR; Phase 4c+ can fork any of these dashboards into the repo if needed.
#
# instanceSelector matches the Grafana CRD's label contract from
# grafana-crd.tf (dashboards=grafana). All platform dashboards bind to the
# singleton Grafana instance in the `observability` namespace.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Kubernetes cluster overview — grafana.com dashboard 15759
# -----------------------------------------------------------------------------
# "Kubernetes / Views / Global" by the Grafana team. Covers: node count,
# pod count, namespace pod breakdown, CPU/memory/network totals, per-node
# pressure. The canonical first-look dashboard for any cluster.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "dashboard_kubernetes_overview" {
  count = local.observability_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "grafana.integreatly.org/v1beta1"
    kind       = "GrafanaDashboard"
    metadata = {
      name      = "kubernetes-cluster-overview"
      namespace = "observability"
      labels = {
        "app.kubernetes.io/part-of" = "platform"
      }
    }
    spec = {
      instanceSelector = {
        matchLabels = {
          dashboards = "grafana"
        }
      }
      # Import the community-maintained dashboard JSON by its grafana.com
      # numeric ID. Revision pinning avoids silent content drift when the
      # author publishes a new revision upstream.
      grafanaCom = {
        id       = 15759
        revision = 37
      }
      resyncPeriod = "1h"
    }
  })

  depends_on = [kubectl_manifest.grafana]
}

# -----------------------------------------------------------------------------
# Karpenter provisioning — grafana.com dashboard 20398
# -----------------------------------------------------------------------------
# Karpenter's own published dashboard. Covers NodeClaim lifecycle, pending
# pods, provisioning latency, interruption rate. Essential during the
# FIS DR drill (ADR-020) — primary-region instances stop; this dashboard
# shows Karpenter attempting to re-provision until the SCP deny holds.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "dashboard_karpenter" {
  count = local.observability_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "grafana.integreatly.org/v1beta1"
    kind       = "GrafanaDashboard"
    metadata = {
      name      = "karpenter-capacity"
      namespace = "observability"
      labels = {
        "app.kubernetes.io/part-of" = "platform"
      }
    }
    spec = {
      instanceSelector = {
        matchLabels = {
          dashboards = "grafana"
        }
      }
      grafanaCom = {
        id       = 20398
        revision = 1
      }
      resyncPeriod = "1h"
    }
  })

  depends_on = [kubectl_manifest.grafana]
}

# -----------------------------------------------------------------------------
# grafana-operator meta-observability — inline JSON
# -----------------------------------------------------------------------------
# Self-monitoring of the observability stack itself (ADR-023 §Known
# Limitations: "Meta-observability is platform-owned by definition").
# Three-panel minimal dashboard — reconcile errors, operator queue depth,
# pod CPU/memory. No public dashboard ID for grafana-operator; inline JSON
# is the minimum viable dashboard until the community ships one.
#
# The JSON is deliberately minimal. Extending it is easy (copy from the
# Grafana UI after authoring panels manually); keeping it small here
# reduces diff noise in this PR.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "dashboard_grafana_operator_meta" {
  count = local.observability_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "grafana.integreatly.org/v1beta1"
    kind       = "GrafanaDashboard"
    metadata = {
      name      = "grafana-operator-meta"
      namespace = "observability"
      labels = {
        "app.kubernetes.io/part-of" = "platform"
      }
    }
    spec = {
      instanceSelector = {
        matchLabels = {
          dashboards = "grafana"
        }
      }
      resyncPeriod = "1h"
      json = jsonencode({
        title         = "grafana-operator meta-observability"
        schemaVersion = 39
        refresh       = "30s"
        time          = { from = "now-6h", to = "now" }
        tags          = ["platform", "meta"]
        panels = [
          {
            id      = 1
            type    = "stat"
            title   = "Reconcile errors (5m rate)"
            gridPos = { h = 6, w = 8, x = 0, y = 0 }
            targets = [{
              expr         = "sum(rate(grafana_operator_reconcile_errors_total[5m]))"
              refId        = "A"
              legendFormat = "errors/s"
            }]
          },
          {
            id      = 2
            type    = "timeseries"
            title   = "Controller workqueue depth"
            gridPos = { h = 8, w = 16, x = 8, y = 0 }
            targets = [{
              expr         = "workqueue_depth{job=\"grafana-operator\"}"
              refId        = "A"
              legendFormat = "{{name}}"
            }]
          },
          {
            id      = 3
            type    = "timeseries"
            title   = "Operator pod memory"
            gridPos = { h = 8, w = 24, x = 0, y = 8 }
            targets = [{
              expr         = "container_memory_working_set_bytes{namespace=\"observability\",pod=~\"grafana-operator-.*\"}"
              refId        = "A"
              legendFormat = "{{pod}}"
            }]
          },
        ]
      })
    }
  })

  depends_on = [kubectl_manifest.grafana]
}
