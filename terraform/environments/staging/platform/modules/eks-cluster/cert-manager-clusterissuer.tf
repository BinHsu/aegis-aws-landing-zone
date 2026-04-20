# -----------------------------------------------------------------------------
# cert-manager ClusterIssuer bootstrap — aegis-core ADR-0031
# -----------------------------------------------------------------------------
# Three-object bootstrap chain for a self-signed CA ClusterIssuer:
#
#   1. `selfsigned-bootstrap` (kind: SelfSigned) — signs only our own CA cert
#   2. `aegis-staging-ca`     (kind: Certificate, isCA: true) — the CA itself,
#                              signed by #1; stores key + cert in a Secret
#   3. `aegis-staging-selfsigned-ca` (kind: ClusterIssuer, ca: { secretName })
#                              — the consumer-facing issuer; aegis-core's
#                              per-workload Certificates reference this name.
#
# Why not a single SelfSigned ClusterIssuer? Because a pure SelfSigned issuer
# signs each workload cert with its own ephemeral key — every cert is its own
# trust anchor. A CA-type issuer signs all workload certs with one key,
# producing a single trust chain that workloads can pin or validate against.
# That single chain is what mTLS between gateway and engine needs.
#
# Cost: zero external dependency, zero AWS cost. Future swap to AWS Private
# CA is a ClusterIssuer backend change (~$400/mo) — aegis-core ADR-0031
# §Migration notes the trigger criteria.
#
# Naming: `aegis-staging-selfsigned-ca` is the exact name aegis-core's
# Certificate CRs reference via `issuerRef`. Changing the name breaks the
# cross-repo contract — do not rename without cross-repo coordination.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "selfsigned_bootstrap_issuer" {
  provider = kubectl.this

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "selfsigned-bootstrap"
    }
    spec = {
      selfSigned = {}
    }
  })

  depends_on = [helm_release.cert_manager]
}

resource "kubectl_manifest" "aegis_staging_ca_cert" {
  provider = kubectl.this

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "aegis-staging-ca"
      namespace = "cert-manager"
    }
    spec = {
      isCA        = true
      commonName  = "aegis-staging-ca"
      secretName  = "aegis-staging-ca-keypair"
      duration    = "87600h" # 10 years — CA cert, lab-tier
      renewBefore = "720h"   # 30 days
      privateKey = {
        algorithm = "ECDSA"
        size      = 256
      }
      issuerRef = {
        name  = "selfsigned-bootstrap"
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
    }
  })

  depends_on = [kubectl_manifest.selfsigned_bootstrap_issuer]
}

resource "kubectl_manifest" "aegis_staging_ca_issuer" {
  provider = kubectl.this

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "aegis-staging-selfsigned-ca"
    }
    spec = {
      ca = {
        secretName = "aegis-staging-ca-keypair"
      }
    }
  })

  depends_on = [kubectl_manifest.aegis_staging_ca_cert]
}
