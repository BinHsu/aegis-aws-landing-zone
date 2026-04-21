# -----------------------------------------------------------------------------
# Grafana CRD — target stack for grafana-operator (ADR-022 Layer 3)
# -----------------------------------------------------------------------------
# The Grafana CRD tells grafana-operator WHICH Grafana instance to reconcile
# against. `spec.external` points at a pre-existing external instance (our
# Grafana Cloud stack) rather than asking the operator to provision a
# Grafana server in-cluster. Auth is via `spec.external.apiKey`, which
# references the K8s Secret created by ExternalSecret in external-secrets.tf.
#
# Label contract — `dashboards: grafana` (and other selector labels) on
# this Grafana CRD are what every GrafanaDashboard / GrafanaContactPoint /
# GrafanaNotificationPolicy CRD targets via its `spec.instanceSelector`.
# The value `grafana` is arbitrary but forms a cluster-wide singleton
# contract: aegis-core's CRDs must use the SAME selector to bind to this
# instance. Changing the value here without coordinating with aegis-core
# breaks the contract — it's part of the cross-repo platform surface.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "grafana" {
  count = local.observability_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "grafana.integreatly.org/v1beta1"
    kind       = "Grafana"
    metadata = {
      name      = "aegis-staging"
      namespace = "observability"
      labels = {
        # Label value — must match the instanceSelector on every
        # GrafanaDashboard / GrafanaContactPoint / GrafanaNotificationPolicy*
        # CRD in the cluster. Cluster-wide singleton.
        dashboards                  = "grafana"
        "app.kubernetes.io/part-of" = "platform"
      }
    }
    spec = {
      external = {
        url = "https://${local.grafana_cloud.org_slug}.grafana.net"
        apiKey = {
          name = "grafana-operator-token"
          key  = "token"
        }
      }
    }
  })

  depends_on = [
    helm_release.grafana_operator,
    kubectl_manifest.external_secret_grafana_operator_token,
  ]
}

# -----------------------------------------------------------------------------
# Root GrafanaNotificationPolicy — platform-owned (ADR-023 §Notification tree)
# -----------------------------------------------------------------------------
# Grafana Cloud's Alertmanager enforces a SINGLE notification policy tree
# per stack; concurrent writers race, last writer wins. The contract
# (ADR-023 §Notification policy tree composition):
#
#   - Root is platform-owned. Exactly ONE GrafanaNotificationPolicy in the
#     cluster, and it lives in the platform namespace (`observability`).
#   - Leaves are service-team-owned via GrafanaNotificationPolicyRoute
#     CRDs in their own namespaces.
#
# The root here defines a catch-all: every alert gets routed via the
# default receiver unless a leaf route matches first. For the lab tier we
# define the default receiver name as `platform-default` — aegis-core will
# ship the actual GrafanaContactPoint (`aegis-oncall-slack` etc.) in its
# own namespace, and their leaf routes will match-and-divert before this
# catch-all fires.
#
# `routeSelector` on the root matches any leaf labeled `tree=aegis-root`.
# That label is the contract surface service teams use to attach their
# leaves — documented in ADR-023.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "notification_policy_root" {
  count = local.observability_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "grafana.integreatly.org/v1beta1"
    kind       = "GrafanaNotificationPolicy"
    metadata = {
      name      = "aegis-root"
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
      route = {
        # Default receiver name — aegis-core (or platform) will ship a
        # GrafanaContactPoint with this name as the fallback target. Not
        # shipping the contact point itself here: platform doesn't pick
        # service-team targets, it only defines the routing shape.
        receiver = "platform-default"
        group_by = ["alertname", "cluster", "namespace"]
        # Leaf-attach point: any GrafanaNotificationPolicyRoute CRD with
        # label `tree=aegis-root` will be composed under this root.
        routeSelector = {
          matchLabels = {
            tree = "aegis-root"
          }
        }
      }
    }
  })

  depends_on = [kubectl_manifest.grafana]
}
