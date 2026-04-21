# -----------------------------------------------------------------------------
# Grafana Alloy — scrape + remote_write + rule forward (ADR-022 Layer 1)
# -----------------------------------------------------------------------------
# Single Deployment instance per cluster. Three jobs:
#
#   1. Discover scrape targets via prometheus-operator CRDs (ServiceMonitor,
#      PodMonitor) and scrape them through Alloy's prometheus.scrape runtime.
#   2. Remote-write all samples to Grafana Cloud Mimir with an external
#      `cluster` label so primary/slave streams are distinguishable in the
#      shared stack (ADR-022 §External label convention).
#   3. Forward PrometheusRule CRDs to the Mimir ruler API for server-side
#      evaluation — cluster control-plane loss does not silence alerts on
#      metrics still being remote-written.
#
# Not used: DaemonSet mode with the Unix exporter. Rationale — Fargate pods
# forbid host mounts (Incident 27), and KSM + kubelet cAdvisor already cover
# the signals Phase 4 cares about (NodeNotReady, CPU/memory pressure, deprec
# API). Node-level /proc metrics can be added in a future PR by deploying a
# separate alloy-daemonset release with a Fargate anti-affinity rule.
#
# `wait = false`: the Alloy pod references the `alloy-token` K8s Secret
# created by ExternalSecret in staging/observability/ (PR-2). Before that
# layer applies, the Secret does not exist and the pod stays
# CreateContainerConfigError. helm_release wait=true would block Terraform
# forever on first apply of platform; false lets Terraform confirm the
# release is installed and move on. Observability-layer apply creates the
# Secret and pods self-heal on next restart.
#
# Auth: Basic auth username = mimir_user_id (from config), password = env
# var GRAFANA_CLOUD_TOKEN sourced from the alloy-token K8s Secret.
# -----------------------------------------------------------------------------

resource "helm_release" "alloy" {
  count = var.observability_enabled ? 1 : 0

  provider = helm.this

  name       = "alloy"
  namespace  = "monitoring"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = "0.9.2"

  wait = false

  values = [
    yamlencode({
      alloy = {
        configMap = {
          content = <<-ALLOY
            // ---------------------------------------------------------------
            // Scrape discovery — Prometheus Operator CRDs (ServiceMonitor /
            // PodMonitor). Wide-open selectors so any workload team's CRDs
            // auto-register (ADR-023 Discovery contract).
            // ---------------------------------------------------------------
            prometheus.operator.servicemonitors "default" {
              forward_to = [prometheus.relabel.drop_pii_and_low_value.receiver]
            }

            prometheus.operator.podmonitors "default" {
              forward_to = [prometheus.relabel.drop_pii_and_low_value.receiver]
            }

            // ---------------------------------------------------------------
            // PII + low-value label drops (ADR-022 §Cardinality and PII)
            // Platform-owned guardrail — executes before remote_write so
            // user-identifying labels cannot accidentally land in Mimir.
            // ---------------------------------------------------------------
            prometheus.relabel "drop_pii_and_low_value" {
              forward_to = [prometheus.remote_write.grafana_cloud.receiver]

              rule {
                action = "labeldrop"
                regex  = "user_id|email|ip_addr|client_ip|user_agent|session_id"
              }

              rule {
                action = "labeldrop"
                regex  = "go_.*|process_.*|promhttp_.*"
              }
            }

            // ---------------------------------------------------------------
            // Remote write → Grafana Cloud Mimir
            // `cluster` external label distinguishes primary vs slave_1
            // streams in the shared stack (ADR-022 §External label).
            // ---------------------------------------------------------------
            prometheus.remote_write "grafana_cloud" {
              endpoint {
                url = "${var.grafana_cloud.mimir_url}"

                basic_auth {
                  username = "${var.grafana_cloud.mimir_user_id}"
                  password = env("GRAFANA_CLOUD_TOKEN")
                }
              }

              external_labels = {
                cluster = "${var.region_key}",
              }
            }

            // ---------------------------------------------------------------
            // Rule forward → Mimir ruler (server-side evaluation)
            // PrometheusRule CRDs reconciled to Mimir via ruler HTTP API.
            // ---------------------------------------------------------------
            mimir.rules.kubernetes "default" {
              address = "${var.grafana_cloud.mimir_url}"

              basic_auth {
                username = "${var.grafana_cloud.mimir_user_id}"
                password = env("GRAFANA_CLOUD_TOKEN")
              }

              rule_selector {}
              rule_namespace_selector {}
            }
          ALLOY
        }

        # alloy-token K8s Secret created by ExternalSecret in the
        # staging/observability/ layer; mounted as env var so Alloy's
        # env("GRAFANA_CLOUD_TOKEN") in the config above resolves.
        extraEnv = [
          {
            name = "GRAFANA_CLOUD_TOKEN"
            valueFrom = {
              secretKeyRef = {
                name = "alloy-token"
                key  = "token"
              }
            }
          },
        ]

        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { memory = "512Mi" }
        }
      }

      controller = {
        type     = "deployment"
        replicas = 1
      }

      # Chart's built-in ServiceMonitor for Alloy self-metrics — CRDs from
      # prometheus-operator-crds are installed before this release
      # (see depends_on below).
      serviceMonitor = {
        enabled = true
      }
    }),
  ]

  depends_on = [
    helm_release.prometheus_operator_crds,
    helm_release.external_secrets,
    kubectl_manifest.cluster_secret_store,
  ]
}
