# -----------------------------------------------------------------------------
# Qdrant ExternalSecret — reconcile credentials into ns aegis (ADR-025, ldz #141)
# -----------------------------------------------------------------------------
# K8s-side reconciler only. The two SSM PS resource shells that this
# ExternalSecret consumes (cluster-url + api-key) live in the
# baseline-tier `staging/secrets-persistent/` layer per ADR-028 — moved
# there after Incident 33 destroyed the values during a workload
# teardown. The ExternalSecret stays here because it targets the `aegis`
# namespace (owned by staging/workloads) and uses the kubectl provider
# wired against the primary cluster, machinery that already exists in
# this layer (ADR-028 §ExternalSecret CRDs stay in observability).
#
# Layer placement note: Qdrant is a vectordb for aegis-engine, not an
# observability concern. The ExternalSecret lives here by precedent
# (team-webhooks ExternalSecret in ns `aegis` from this layer) rather
# than category. ADR-027 enumerates the triggers that would justify
# extracting this block into a new `staging/data-secrets/` layer; none
# fire today.
#
# Contract with aegis-core (ldz #141):
#   - K8s Secret: `qdrant-credentials` in ns `aegis`
#   - Keys: `QDRANT_URL`, `QDRANT_API_KEY` (uppercase, env-var convention)
#   - URL shape: `https://<cluster-host>:6334` (gRPC port, TLS on — the
#     engine's qdrant_client infers TLS from the scheme; bare host means
#     plaintext). See engine_cpp/src/vectordb/qdrant_client.cc:132.
# Changing names requires cross-repo coordination; do not unilaterally rename.
#
# Dual-gate: qdrant_enabled (feature on) AND platform_applied (cluster
# exists). On cold cycle the ExternalSecret is skipped — a re-apply of
# this layer after staging/platform applies reconciles it.
#
# No Terraform-state-level depends_on for the SSM PS resources — they
# live in another state (staging/secrets-persistent). Apply-time
# ordering is enforced by the workflow split: baseline (which includes
# secrets-persistent) runs before workload (which includes
# observability). Out-of-order local applies surface as ESO retry loops
# at runtime ("Secret not found"), not as Terraform errors.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "external_secret_qdrant_credentials" {
  count = (local.qdrant_enabled && local.platform_applied) ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "qdrant-credentials"
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
        name           = "qdrant-credentials"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "QDRANT_URL"
          remoteRef = {
            key = "${local.qdrant_ssm_path_prefix}/cluster-url"
          }
        },
        {
          secretKey = "QDRANT_API_KEY"
          remoteRef = {
            key = "${local.qdrant_ssm_path_prefix}/api-key"
          }
        },
      ]
    }
  })
}
