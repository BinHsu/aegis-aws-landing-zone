# -----------------------------------------------------------------------------
# Argo Rollouts controller + ALB traffic-router plugin — aegis-core ADR-0030
# -----------------------------------------------------------------------------
# Deployed as an ArgoCD Application (same pattern as kube-prometheus-stack
# in observability.tf). ArgoCD manages the Helm release lifecycle; Terraform
# manages the Application CRD itself.
#
# Unlike Kyverno (which lives in platform/ as helm_release because downstream
# TF resources need synchronous CRD availability), Argo Rollouts' CRDs
# (Rollout, AnalysisTemplate) are consumed by aegis-core ONLY — ldz Terraform
# creates no Argo Rollouts CRDs. There is no race concern, so the ArgoCD
# Application pattern is correct for this component.
#
# ALB traffic-router plugin: the rollouts-plugin-trafficrouter-alb binary is
# declared via Helm values `controller.trafficRouterPlugins`; the chart
# materializes it into a ConfigMap the controller reads at startup. aegis-core
# C-5a Rollout CRs reference the plugin as `trafficRouting: { plugins: {
# argoproj-labs/alb: { ... } } }`.
#
# Consumed by aegis-core per ADR-0030:
#   - C-5a: step-based canary (10% → 30% → 60% → 100%)
#   - C-5b (Phase 4d): SLO-gated canary via AnalysisTemplate
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "argo_rollouts" {
  provider = kubectl.this

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "argo-rollouts"
      namespace = "argocd"
      finalizers = [
        "resources-finalizer.argocd.argoproj.io",
      ]
    }
    spec = {
      project = "default"

      source = {
        repoURL        = "https://argoproj.github.io/argo-helm"
        targetRevision = "2.37.7"
        chart          = "argo-rollouts"

        helm = {
          releaseName = "argo-rollouts"
          values = yamlencode({
            controller = {
              resources = {
                requests = { cpu = "50m", memory = "128Mi" }
                limits   = { memory = "256Mi" }
              }

              # ALB traffic-router plugin — chart materializes this as a
              # ConfigMap the controller reads on startup. Plugin binary is
              # downloaded at runtime; sha256 pinning is documented in the
              # upstream plugin repo.
              trafficRouterPlugins = {
                trafficRouterPlugins = yamlencode([{
                  name     = "argoproj-labs/alb"
                  location = "https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-alb/releases/download/v0.4.1/rollout-plugin-alb-linux-amd64"
                }])
              }

              # Emit Prometheus metrics via the ServiceMonitor CRD (auto-
              # discovered by the platform Prometheus per ADR-015).
              metrics = {
                enabled = true
                serviceMonitor = {
                  enabled = true
                }
              }
            }

            dashboard = {
              enabled = true
              resources = {
                requests = { cpu = "25m", memory = "64Mi" }
                limits   = { memory = "128Mi" }
              }
            }
          })
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argo-rollouts"
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
