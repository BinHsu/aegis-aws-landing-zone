# -----------------------------------------------------------------------------
# observability namespace — home of grafana-operator + the Grafana CRD
# -----------------------------------------------------------------------------
# Coordination Point 2 from aegis-core #46: the Grafana CRD lives in
# `observability/`, and grafana-operator's `instanceSelector` scans
# cluster-wide for dashboards, contact points, and notification routes.
# This means aegis-core's per-service CRDs live in the `aegis` namespace
# and grafana-operator picks them up via label selector without any
# cross-namespace RBAC gymnastics.
#
# Why a dedicated namespace (not `monitoring`): `monitoring` is owned by
# staging/platform (Alloy, prometheus-operator-crds, kube-state-metrics)
# and represents the data-plane of the observability stack — what IS
# scraped and shipped. `observability` owns the control-plane — what
# configures the dashboards, alerting routes, and the Grafana-side stack
# identity. Separating the two makes the RBAC + NetworkPolicy story
# cleaner when/if either namespace needs tightening.
# -----------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "observability" {
  count = local.observability_enabled ? 1 : 0

  metadata {
    name = "observability"

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "platform"
      # Pod Security Standards — grafana-operator runs as non-root,
      # read-only root FS, no privileged capabilities. `restricted`
      # is the tightest PSS tier and is the correct profile.
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}
