# -----------------------------------------------------------------------------
# Default-deny NetworkPolicy — ADR-017
# -----------------------------------------------------------------------------
# Denies all ingress and egress in the aegis namespace by default. Workload
# manifests (in aegis-core) must create explicit allow rules for:
#   - gateway ← ALB ingress
#   - engine  ← gateway (gRPC)
#   - egress  → DNS (kube-dns), AWS APIs (HTTPS)
#
# This is a security posture decision: deny-by-default means a
# misconfigured workload cannot communicate until explicitly allowed.
# The NetworkPolicy only takes effect when a CNI that supports
# NetworkPolicy is installed (VPC CNI with network policy support,
# enabled by default on EKS 1.25+).
# -----------------------------------------------------------------------------

resource "kubernetes_network_policy_v1" "default_deny" {
  provider = kubernetes.this

  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace_v1.aegis.metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Ingress", "Egress"]
  }
}

# -----------------------------------------------------------------------------
# Allow DNS egress — without this, pods cannot resolve service names.
# Scoped to kube-dns on port 53 (TCP + UDP).
# -----------------------------------------------------------------------------

resource "kubernetes_network_policy_v1" "allow_dns" {
  provider = kubernetes.this

  metadata {
    name      = "allow-dns-egress"
    namespace = kubernetes_namespace_v1.aegis.metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Egress"]

    egress {
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }

      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }
        pod_selector {
          match_labels = {
            "k8s-app" = "kube-dns"
          }
        }
      }
    }
  }
}
