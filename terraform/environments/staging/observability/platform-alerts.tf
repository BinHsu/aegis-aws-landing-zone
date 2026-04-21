# -----------------------------------------------------------------------------
# Platform-owned PrometheusRule CRDs (ADR-023 §Domain split)
# -----------------------------------------------------------------------------
# Four alerts ship at this PR:
#
#   1. NodeNotReady — moved over from the deleted kube-prometheus-stack
#      observability.tf (Session D Incident 26 context). Canonical signal
#      for the FIS DR drill (ADR-020).
#   2. KubernetesDeprecatedAPIUsed — moved over from the deleted chart.
#      Change-review-discipline §3.4 requires this one.
#   3. GrafanaOperatorReconcileFailed — meta-observability. Fires when the
#      operator cannot reconcile its CRDs. If this alert fires during a
#      dashboard push, the push is unreliable until the operator recovers.
#   4. GrafanaCloudCardinalityApproaching8k — capacity guardrail. Grafana
#      Cloud free tier caps at 10k active series; firing at 8k gives 20%
#      headroom to diagnose and cut cardinality before ingestion throttle.
#
# Annotations preserved verbatim from the old kube-prometheus-stack rules
# where applicable — operators already familiar with the summary/description
# text don't need to relearn wording.
#
# Server-side evaluation: Alloy's `mimir.rules.kubernetes "default"` block
# (staging/platform/modules/eks-cluster/alloy.tf) discovers these CRDs and
# forwards them to Grafana Cloud Mimir ruler. Cluster control-plane loss
# does NOT silence these alerts for metrics that are already being
# remote_written (ADR-022 §Rule evaluation location).
#
# One PrometheusRule per concern (not a mega-rule with all groups) —
# keeps diffs surgical when any single rule changes.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# 1. NodeNotReady — FIS drill signal (ADR-020)
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "rule_node_not_ready" {
  count = local.observability_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "node-not-ready"
      namespace = "observability"
      labels = {
        "app.kubernetes.io/part-of" = "platform"
      }
    }
    spec = {
      groups = [{
        name = "dr-drill"
        rules = [{
          alert = "NodeNotReady"
          expr  = "kube_node_status_condition{condition=\"Ready\",status=\"true\"} == 0"
          for   = "1m"
          labels = {
            severity = "warning"
            drill    = "fis-primary-outage"
          }
          annotations = {
            summary     = "Node {{ $labels.node }} is NotReady"
            description = "Node {{ $labels.node }} has been NotReady for >1 minute. Expected during the FIS primary-outage drill (ADR-020); investigate if no drill is running."
          }
        }]
      }]
    }
  })

  depends_on = [helm_release.grafana_operator]
}

# -----------------------------------------------------------------------------
# 2. KubernetesDeprecatedAPIUsed — change-review-discipline §3.4
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "rule_deprecated_apis" {
  count = local.observability_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "deprecated-apis"
      namespace = "observability"
      labels = {
        "app.kubernetes.io/part-of" = "platform"
      }
    }
    spec = {
      groups = [{
        name = "deprecated-api-detection"
        rules = [{
          alert = "KubernetesDeprecatedAPIUsed"
          expr  = "apiserver_requested_deprecated_apis > 0"
          for   = "5m"
          labels = {
            severity = "warning"
          }
          annotations = {
            summary     = "Deprecated Kubernetes API in use"
            description = "The API {{ $labels.resource }}.{{ $labels.group }}/{{ $labels.version }} is deprecated. Migrate before the removal version."
          }
        }]
      }]
    }
  })

  depends_on = [helm_release.grafana_operator]
}

# -----------------------------------------------------------------------------
# 3. GrafanaOperatorReconcileFailed — meta-observability
# -----------------------------------------------------------------------------
# If grafana-operator cannot reconcile, every dashboard/alert/route push
# silently fails (ADR-023 §Known Limitations "Meta-observability"). 10-minute
# for-duration tolerates transient Grafana Cloud API hiccups without pages.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "rule_grafana_operator_reconcile_failed" {
  count = local.observability_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "grafana-operator-reconcile-failed"
      namespace = "observability"
      labels = {
        "app.kubernetes.io/part-of" = "platform"
      }
    }
    spec = {
      groups = [{
        name = "meta-observability"
        rules = [{
          alert = "GrafanaOperatorReconcileFailed"
          expr  = "sum(rate(grafana_operator_reconcile_errors_total[10m])) > 0"
          for   = "10m"
          labels = {
            severity = "warning"
          }
          annotations = {
            summary     = "grafana-operator reconcile failing"
            description = "grafana-operator has been emitting reconcile errors for >10 minutes. Dashboard / alert / contact point pushes to Grafana Cloud are unreliable until this clears. Check operator logs: kubectl -n observability logs deploy/grafana-operator-controller-manager."
          }
        }]
      }]
    }
  })

  depends_on = [helm_release.grafana_operator]
}

# -----------------------------------------------------------------------------
# 4. GrafanaCloudCardinalityApproaching8k — capacity guardrail
# -----------------------------------------------------------------------------
# Grafana Cloud free tier: 10k active series cap, throttle-on-overage. Alert
# at 8k (80%) to leave headroom for diagnosis (ADR-022 §Cardinality budget).
# `grafana_cloud_active_series_total` is exposed by Grafana Cloud's usage
# endpoint, scraped by Alloy as a self-scrape target — the Alloy config is
# a follow-up (TODO when the self-scrape target is wired up in PR-3 or a
# subsequent tightening). Until then this rule is defined but may evaluate
# to `no data` — that's intentional; the rule being present + named is
# the change, wiring the metric into scrape is the follow-up.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "rule_grafana_cloud_cardinality" {
  count = local.observability_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "grafana-cloud-cardinality"
      namespace = "observability"
      labels = {
        "app.kubernetes.io/part-of" = "platform"
      }
    }
    spec = {
      groups = [{
        name = "cardinality-guardrail"
        rules = [{
          alert = "GrafanaCloudCardinalityApproaching8k"
          expr  = "grafana_cloud_active_series_total > 8000"
          for   = "10m"
          labels = {
            severity = "warning"
          }
          annotations = {
            summary     = "Grafana Cloud active series > 8k (80% of 10k cap)"
            description = "Grafana Cloud active series has exceeded 8,000 for 10 minutes. Throttle starts at 10k — reduce cardinality before hitting the cap. Run cardinality audit: curl Alloy /debug/prometheus/self. See ADR-022 §Cardinality for the budget allocation."
          }
        }]
      }]
    }
  })

  depends_on = [helm_release.grafana_operator]
}
