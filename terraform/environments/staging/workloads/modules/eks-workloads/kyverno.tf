# -----------------------------------------------------------------------------
# Kyverno admission controller — ADR-016
# -----------------------------------------------------------------------------
# Deployed as an ArgoCD Application (same pattern as kube-prometheus-stack
# in observability.tf). ArgoCD manages the Helm release; Terraform manages
# the Application CRD and the ClusterPolicy resources.
#
# Kyverno intercepts every pod creation via a mutating/validating webhook.
# Failure mode: failOpen (default) — if Kyverno is down, pods are admitted
# without policy checks. Acceptable for a lab; production would use failClose.
#
# Cost: ~100m CPU, ~200Mi memory on a Karpenter Spot node. Negligible.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "kyverno" {
  provider = kubectl.this

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "kyverno"
      namespace = "argocd"
      finalizers = [
        "resources-finalizer.argocd.argoproj.io",
      ]
    }
    spec = {
      project = "default"

      source = {
        repoURL        = "https://kyverno.github.io/kyverno"
        targetRevision = "3.4.1"
        chart          = "kyverno"

        helm = {
          releaseName = "kyverno"
          values = yamlencode({
            admissionController = {
              replicas = 1
              resources = {
                requests = { cpu = "100m", memory = "200Mi" }
                limits   = { memory = "384Mi" }
              }
            }

            backgroundController = {
              resources = {
                requests = { cpu = "50m", memory = "64Mi" }
                limits   = { memory = "128Mi" }
              }
            }

            cleanupController = {
              resources = {
                requests = { cpu = "50m", memory = "64Mi" }
                limits   = { memory = "128Mi" }
              }
            }

            reportsController = {
              resources = {
                requests = { cpu = "50m", memory = "64Mi" }
                limits   = { memory = "128Mi" }
              }
            }
          })
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "kyverno"
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true",
        ]
      }
    }
  })

  depends_on = [kubernetes_namespace_v1.aegis]
}

# -----------------------------------------------------------------------------
# Baseline ClusterPolicies — ADR-016
# -----------------------------------------------------------------------------
# All policies start in `Audit` mode: violations are logged in Kyverno
# policy reports but pods are NOT rejected. Switch to `Enforce` after
# verifying no false positives against platform pods.
#
# These are kubectl_manifest (not kubernetes_manifest) because Kyverno's
# ClusterPolicy CRD only exists after the Kyverno Helm chart is installed.
# The kubectl provider's deferred schema validation handles this bootstrap
# ordering — same pattern as Karpenter NodePool in staging/platform.
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

  depends_on = [kubectl_manifest.kyverno]
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

  depends_on = [kubectl_manifest.kyverno]
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

  depends_on = [kubectl_manifest.kyverno]
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

  depends_on = [kubectl_manifest.kyverno]
}
