# -----------------------------------------------------------------------------
# ArgoCD — GitOps bootstrap via Helm + app-of-apps root Application
# -----------------------------------------------------------------------------
# Per ADR-013 + ADR-018: each cluster gets its OWN ArgoCD Helm release. No
# central controller managing remote clusters — avoids the "central ArgoCD
# becomes a new SPOF during primary-region outage" problem (ADR-018 §7).
#
# All ArgoCDs point at the same var.github_app_repo; the apps path is a
# variable so a slave region can target a subset (pilot-light) if needed.
# -----------------------------------------------------------------------------

resource "helm_release" "argocd" {
  provider = helm.this

  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.6.12"

  values = [
    yamlencode({
      controller = {
        replicas = 1
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }

      server = {
        replicas = 1
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
        service = {
          type = "ClusterIP"
        }
      }

      repoServer = {
        replicas = 1
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }

      redis = {
        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { cpu = "200m", memory = "128Mi" }
        }
      }

      dex = {
        enabled = false
      }
    }),
  ]

  depends_on = [
    helm_release.karpenter,
    # LB Controller webhook must be ready before ArgoCD Services hit
    # admission. See Incident 17.
    helm_release.aws_lb_controller,
    kubectl_manifest.aegis_cluster_admin_binding,
  ]
}

# -----------------------------------------------------------------------------
# App-of-Apps root Application (per-cluster)
# -----------------------------------------------------------------------------
resource "kubectl_manifest" "argocd_root_app" {
  provider = kubectl.this

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root"
      namespace = "argocd"
      finalizers = [
        "resources-finalizer.argocd.argoproj.io",
      ]
    }
    spec = {
      project = "default"

      source = {
        repoURL        = "https://github.com/${var.github_org}/${var.github_app_repo}.git"
        targetRevision = "main"
        path           = var.argocd_apps_path
        directory = {
          recurse = true
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
        ]
      }
    }
  })

  depends_on = [helm_release.argocd]
}
