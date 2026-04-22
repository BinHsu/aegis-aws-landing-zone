# -----------------------------------------------------------------------------
# grafana-operator — PRIMARY CLUSTER ONLY (ADR-022 §Multi-region)
# -----------------------------------------------------------------------------
# grafana-operator reconciles Kubernetes CRDs (Grafana, GrafanaDashboard,
# GrafanaContactPoint, GrafanaNotificationPolicy, GrafanaNotificationPolicyRoute,
# GrafanaMuteTiming) against a SINGLE Grafana Cloud stack. If both slot
# clusters ran grafana-operator, they would race on identical Grafana Cloud
# resources (last-writer-wins thrash, never converges).
#
# This layer's providers target the primary cluster only. grafana-operator
# is therefore installed once, on the primary, regardless of how many EKS
# slots the config declares. Slave-cluster observability is data-plane
# (Alloy remote_write in staging/platform) — not control-plane.
#
# Chart: grafana/grafana-operator 5.22.2 (current stable at PR time). The
# operator CRDs ship INSIDE this chart — enabling `installCRDs = true` is
# how the Grafana* CRDs become available for our own kubectl_manifest
# resources (the Grafana CRD + root NotificationPolicy below).
#
# wait = true so helm_release blocks until the operator Deployment is
# Ready. Downstream kubectl_manifest resources (Grafana CRD, dashboards,
# alerts) depend_on this release — wait=true guarantees the CRDs are
# registered before those manifests apply.
#
# Cost: grafana-operator sits at ~50m CPU / 128Mi memory idle. Negligible
# at lab scale (one operator vs kube-prometheus-stack's full Prometheus +
# Grafana + Alertmanager footprint this replaces — ADR-022 reversal).
# -----------------------------------------------------------------------------

resource "helm_release" "grafana_operator" {
  count = local.observability_enabled ? 1 : 0

  name       = "grafana-operator"
  namespace  = "observability"
  repository = "oci://ghcr.io/grafana/helm-charts"
  chart      = "grafana-operator"
  version    = "v5.22.2"

  wait = true

  values = [
    yamlencode({
      # CRD management: chart installs Grafana, GrafanaDashboard, etc.
      # into the cluster. Our kubectl_manifest resources below reference
      # these CRDs — wait=true + CRD install happening in this same
      # helm_release guarantees the schema is registered before
      # Terraform attempts to apply any downstream Grafana* manifest.
      installCRDs = true

      # Resource limits — lab-tier, single operator per stack.
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "256Mi" }
      }

      # ServiceMonitor for self-metrics — platform-owned observability of
      # the observability stack itself (meta-observability per ADR-023
      # §Known Limitations). Alloy scrapes this ServiceMonitor via the
      # wide-open selector in staging/platform/modules/eks-cluster/alloy.tf.
      serviceMonitor = {
        enabled = true
      }
    }),
  ]

  depends_on = [
    kubernetes_namespace_v1.observability,
    # ExternalSecret must exist before the Grafana CRD tries to reference
    # its K8s Secret output. The Grafana CRD apply itself is gated
    # separately in grafana-crd.tf, but installing grafana-operator before
    # ESO has synced the token avoids a reconcile-loop error spike on
    # first-apply that we would then have to clear from dashboards.
    kubectl_manifest.external_secret_grafana_operator_token,
  ]
}
