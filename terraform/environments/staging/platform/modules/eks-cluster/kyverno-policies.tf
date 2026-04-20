# -----------------------------------------------------------------------------
# Baseline Kyverno ClusterPolicies — ADR-016
# -----------------------------------------------------------------------------
# All policies start in `Audit` mode: violations are logged in Kyverno policy
# reports but pods are NOT rejected. Switch to `Enforce` after verifying no
# false positives against platform pods (Karpenter, ArgoCD, LBC, CoreDNS).
#
# These are platform-authored policies (per ADR-016 §Policies deployed in
# Phase 4c), co-located with the Kyverno Helm install so the CRD → policy
# relationship is obvious and the cross-layer handoff is eliminated.
#
# kubectl_manifest (not kubernetes_manifest) because the ClusterPolicy CRD
# only exists after the Kyverno Helm chart is installed; the kubectl provider
# defers schema validation to apply-time, which pairs cleanly with helm_release
# completing synchronously before these resources plan.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "policy_deny_privileged" {
  provider = kubectl.this

  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "deny-privileged-containers"
      annotations = {
        "policies.kyverno.io/title"       = "Deny Privileged Containers"
        "policies.kyverno.io/category"    = "Pod Security"
        "policies.kyverno.io/severity"    = "high"
        "policies.kyverno.io/description" = "Privileged containers have full access to the host. Block them."
      }
    }
    spec = {
      validationFailureAction = "Audit"
      background              = true
      rules = [{
        name = "deny-privileged"
        match = {
          any = [{
            resources = {
              kinds = ["Pod"]
            }
          }]
        }
        validate = {
          message = "Privileged containers are not allowed."
          pattern = {
            spec = {
              containers = [{
                securityContext = {
                  privileged = "!true"
                }
              }]
            }
          }
        }
      }]
    }
  })

  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "policy_deny_host_namespaces" {
  provider = kubectl.this

  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "deny-host-namespaces"
      annotations = {
        "policies.kyverno.io/title"       = "Deny Host Namespaces"
        "policies.kyverno.io/category"    = "Pod Security"
        "policies.kyverno.io/severity"    = "high"
        "policies.kyverno.io/description" = "Pods using host namespaces can access host-level resources. Block hostNetwork, hostPID, hostIPC."
      }
    }
    spec = {
      validationFailureAction = "Audit"
      background              = true
      rules = [{
        name = "deny-host-namespaces"
        match = {
          any = [{
            resources = {
              kinds = ["Pod"]
            }
          }]
        }
        validate = {
          message = "Host namespaces (hostNetwork, hostPID, hostIPC) are not allowed."
          pattern = {
            spec = {
              "=(hostNetwork)" = false
              "=(hostPID)"     = false
              "=(hostIPC)"     = false
            }
          }
        }
      }]
    }
  })

  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "policy_require_limits" {
  provider = kubectl.this

  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "require-resource-limits"
      annotations = {
        "policies.kyverno.io/title"       = "Require Resource Limits"
        "policies.kyverno.io/category"    = "Best Practices"
        "policies.kyverno.io/severity"    = "medium"
        "policies.kyverno.io/description" = "Pods without memory limits can cause OOM kills on shared nodes. Require limits.memory on all containers."
      }
    }
    spec = {
      validationFailureAction = "Audit"
      background              = true
      rules = [{
        name = "require-memory-limits"
        match = {
          any = [{
            resources = {
              kinds = ["Pod"]
            }
          }]
        }
        validate = {
          message = "All containers must have resources.limits.memory defined."
          pattern = {
            spec = {
              containers = [{
                resources = {
                  limits = {
                    memory = "?*"
                  }
                }
              }]
            }
          }
        }
      }]
    }
  })

  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "policy_require_labels" {
  provider = kubectl.this

  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "require-app-labels"
      annotations = {
        "policies.kyverno.io/title"       = "Require Application Labels"
        "policies.kyverno.io/category"    = "Best Practices"
        "policies.kyverno.io/severity"    = "medium"
        "policies.kyverno.io/description" = "Deployments must have app.kubernetes.io/name label for observability and service discovery."
      }
    }
    spec = {
      validationFailureAction = "Audit"
      background              = true
      rules = [{
        name = "require-app-name-label"
        match = {
          any = [{
            resources = {
              kinds = ["Deployment"]
            }
          }]
        }
        validate = {
          message = "Deployments must have the label 'app.kubernetes.io/name'."
          pattern = {
            metadata = {
              labels = {
                "app.kubernetes.io/name" = "?*"
              }
            }
          }
        }
      }]
    }
  })

  depends_on = [helm_release.kyverno]
}
