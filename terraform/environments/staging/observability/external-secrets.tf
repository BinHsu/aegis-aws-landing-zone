# -----------------------------------------------------------------------------
# ExternalSecrets — pull SSM PS SecureStrings into K8s Secrets (ADR-022)
# -----------------------------------------------------------------------------
# Three ExternalSecret manifests, one per downstream token. All three
# reference the `aegis-ssm` ClusterSecretStore created in staging/platform
# (PR-1). Naming + key contracts are locked — the consumer side (Alloy
# extraEnv in staging/platform; grafana-operator Grafana CRD in this layer;
# aegis-core's GrafanaContactPoint CRDs) hard-codes these exact strings.
#
# Refresh interval (1h default) is acceptable for 90-day rotating tokens —
# External Secrets picks up rotations within the hour without manual
# intervention. Tightening to 5m would matter only for secrets that rotate
# on minutes-scale (none here).
#
# kubectl_manifest over kubernetes_manifest: ExternalSecret is a CRD shipped
# by the External Secrets Operator chart. kubernetes_manifest requires the
# CRD to be reachable at plan time, which fails on cold apply if ESO's helm
# release has not yet installed its CRDs. kubectl_manifest defers schema
# validation to apply time — identical pattern to staging/platform's
# kubectl_manifest usage for CRD-backed resources.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# alloy-token — consumed by Alloy Deployment in `monitoring` ns
# -----------------------------------------------------------------------------
# Contract with staging/platform/modules/eks-cluster/alloy.tf:
#   extraEnv[0] references K8s Secret `alloy-token` key `token` → mounted
#   as env var GRAFANA_CLOUD_TOKEN → Alloy config env("GRAFANA_CLOUD_TOKEN")
#   resolves to this secret's value.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "external_secret_alloy_token" {
  count = local.observability_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "alloy-token"
      namespace = "monitoring"
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/part-of"    = "platform"
      }
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "aegis-ssm"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "alloy-token"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "token"
          remoteRef = {
            key = "${local.ssm_path_prefix}/alloy-token"
          }
        },
      ]
    }
  })

  depends_on = [aws_ssm_parameter.alloy_token]
}

# -----------------------------------------------------------------------------
# grafana-operator-token — consumed by the Grafana CRD (spec.external.apiKey)
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "external_secret_grafana_operator_token" {
  count = local.observability_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "grafana-operator-token"
      namespace = "observability"
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/part-of"    = "platform"
      }
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "aegis-ssm"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "grafana-operator-token"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "token"
          remoteRef = {
            key = "${local.ssm_path_prefix}/grafana-operator-token"
          }
        },
      ]
    }
  })

  depends_on = [
    kubernetes_namespace_v1.observability,
    aws_ssm_parameter.grafana_operator_token,
  ]
}

# -----------------------------------------------------------------------------
# team-webhooks — consumed by aegis-core's GrafanaContactPoint CRD
# -----------------------------------------------------------------------------
# Multi-key secret (ADR-023 §Secret plumbing model). Today only one key
# (`slack-aegis`) exists; future team onboarding adds keys alongside (e.g.
# `slack-platform`, `slack-billing`). The ExternalSecret's `data` list is
# the single source of truth for which keys exist — adding a team = adding
# an entry here and a matching SSM PS parameter in tokens.tf.
#
# Target namespace `aegis` is owned by staging/workloads (via
# modules/eks-workloads/namespace.tf). Apply order: network → platform →
# workloads → observability, enforced by terraform-apply-workload.yml.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "external_secret_team_webhooks" {
  count = local.observability_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "team-webhooks"
      namespace = "aegis"
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/part-of"    = "platform"
      }
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "aegis-ssm"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "team-webhooks"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "slack-aegis"
          remoteRef = {
            key = "${local.ssm_path_prefix}/team-webhooks-slack-aegis"
          }
        },
      ]
    }
  })

  depends_on = [aws_ssm_parameter.team_webhooks_slack_aegis]
}
