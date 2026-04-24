# -----------------------------------------------------------------------------
# ExternalSecret — sync Cognito identifiers into aegis namespace (ADR-026)
# -----------------------------------------------------------------------------
# Single ExternalSecret in the `aegis` namespace, reconciled by External
# Secrets Operator via the `aegis-ssm` ClusterSecretStore (installed in
# staging/platform PR-1). Produces a K8s Secret `cognito-config` with
# three keys (COGNITO_USER_POOL_ID, COGNITO_APP_CLIENT_ID,
# COGNITO_ISSUER_URL) that aegis-core's gateway Deployment consumes via
# `envFrom` or `secretKeyRef`.
#
# Naming is a hard contract (ADR-026 §Decision):
#   - Secret name `cognito-config`
#   - Key names `COGNITO_USER_POOL_ID`, `COGNITO_APP_CLIENT_ID`,
#     `COGNITO_ISSUER_URL`
# Changing these requires a cross-repo amendment with aegis-core, not a
# unilateral refactor.
#
# Target namespace `aegis` is owned by staging/workloads
# (modules/eks-workloads/namespace.tf). On a cold cycle where workloads
# has not been applied yet, this kubectl_manifest fails with
# `namespaces "aegis" not found`. That is the intended failure mode:
# operator sees the error, applies workloads, re-dispatches baseline.
# The AWS-side resources (user pool, app client, domain, SSM params)
# apply cleanly regardless.
#
# kubectl_manifest over kubernetes_manifest: ExternalSecret is a CRD
# shipped by ESO. kubernetes_manifest requires the CRD to be reachable
# at plan time which fails on cold apply before ESO has installed its
# CRDs. kubectl_manifest defers schema validation to apply time —
# identical pattern to staging/observability/external-secrets.tf.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "external_secret_cognito_config" {
  # Gate: both auth_enabled (cognito block in config) AND platform_applied
  # (staging/platform has produced a cluster output). Without the second
  # clause the kubectl provider tries to dial an unresolvable host and
  # fails the whole apply even though AWS-side resources created cleanly.
  # On cold-cycle first apply the operator sees this ExternalSecret
  # skipped, applies staging/platform (via workloads), and re-dispatches
  # baseline — the second pass picks up platform_applied=true and
  # reconciles the ExternalSecret.
  count = local.platform_applied ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "cognito-config"
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
        name           = "cognito-config"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "COGNITO_USER_POOL_ID"
          remoteRef = {
            key = "${local.ssm_path_prefix}/user-pool-id"
          }
        },
        {
          secretKey = "COGNITO_APP_CLIENT_ID"
          remoteRef = {
            key = "${local.ssm_path_prefix}/app-client-id"
          }
        },
        {
          secretKey = "COGNITO_ISSUER_URL"
          remoteRef = {
            key = "${local.ssm_path_prefix}/issuer-url"
          }
        },
      ]
    }
  })

  depends_on = [
    aws_ssm_parameter.user_pool_id,
    aws_ssm_parameter.app_client_id,
    aws_ssm_parameter.issuer_url,
  ]
}
