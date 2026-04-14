# -----------------------------------------------------------------------------
# ArgoCD — GitOps bootstrap via Helm + app-of-apps root Application
# -----------------------------------------------------------------------------
# Per ADR-013 "GitOps bootstrap", Terraform installs ArgoCD once. After
# that install, ArgoCD's own `Application` resource points at the
# aegis-core repository, and every subsequent workload deployment is a
# commit to aegis-core — not a Terraform change here.
#
# The root Application below targets `apps/staging/` in aegis-core,
# following the App-of-Apps pattern (CLAUDE.md): the root Application's
# manifest is a directory of child Applications, each of which points at
# its own manifest location in the same repo.
#
# Authentication: ArgoCD accesses the public aegis-core repo anonymously.
# When aegis-core becomes private (Phase 4+) or when cross-account image
# pulls need per-environment secrets, add a repository credential via
# `argocd-cm` and an SSH/HTTPS credential via `argocd-secret`. Not in
# scope here because aegis-core is currently a public repo.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# ArgoCD namespace is created by the chart; use a dedicated namespace so
# teardown of ArgoCD is a clean namespace delete.
# -----------------------------------------------------------------------------
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.6.12" # ArgoCD 2.12.x — pinned for reproducibility

  values = [
    yamlencode({
      # Controller + repo server + application controller sizing for a lab
      # with a handful of apps. Keep it small to fit on one Karpenter EC2.
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

        # Internal-only Service for now. Phase 3c PR 3 establishes the
        # controller but not the public ingress; a follow-up PR adds an
        # Ingress resource with ACM TLS once DNS is wired up.
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

      # Redis (cached application manifests). Single replica lab-sized.
      redis = {
        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { cpu = "200m", memory = "128Mi" }
        }
      }

      # Dex (SSO proxy) disabled — we do not wire up external SSO to
      # ArgoCD in this phase. The admin password is stored in the
      # `argocd-initial-admin-secret` Secret and can be read via
      # `kubectl -n argocd get secret argocd-initial-admin-secret \
      #   -o jsonpath='{.data.password}' | base64 -d`
      dex = {
        enabled = false
      }
    }),
  ]

  depends_on = [
    helm_release.karpenter, # ArgoCD needs EC2 capacity to schedule on
    # AWS LB Controller installs a MutatingWebhookConfiguration that
    # intercepts every Service creation. If Karpenter creates the Services
    # in the same apply pass as the LB Controller (parallel helm installs),
    # the webhook may have no backing endpoints yet — ArgoCD's Services
    # then fail admission with:
    #   "no endpoints available for service aws-load-balancer-webhook-service"
    # Serialize the install so LB Controller's webhook is reachable before
    # ArgoCD's Services hit admission. See Incident 17 in docs/incidents.md.
    helm_release.aws_lb_controller,
    # Cluster-admin binding — see cluster-role-binding.tf and Incident 21.
    kubectl_manifest.aegis_cluster_admin_binding,
  ]
}

# -----------------------------------------------------------------------------
# App-of-Apps root Application
# -----------------------------------------------------------------------------
# The root Application points at a directory in aegis-core that contains
# child Application manifests. ArgoCD discovers and manages them
# automatically. Adding a new workload is a commit to aegis-core —
# no Terraform change here.
#
# Auto-sync is enabled (per CLAUDE.md: "Auto-sync for staging, manual
# sync for prod"). `selfHeal = true` re-applies drift; `prune = true`
# deletes child resources removed from the repo.
# -----------------------------------------------------------------------------
# kubectl_manifest (not kubernetes_manifest) — deferred plan-time schema
# validation. See the bootstrap-trap note in karpenter-nodepool.tf +
# Incident 10.
resource "kubectl_manifest" "argocd_root_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root"
      namespace = "argocd"
      # The `finalizer` ensures ArgoCD cascades deletion of child apps
      # when the root is deleted (cleaner teardown).
      finalizers = [
        "resources-finalizer.argocd.argoproj.io",
      ]
    }
    spec = {
      project = "default"

      source = {
        repoURL        = "https://github.com/${local.config.github.org}/${local.config.github.app_repo}.git"
        targetRevision = "main"
        # Child applications live under apps/staging/ in aegis-core. The
        # directory is read with `recurse: true` so sub-directories can
        # structure apps (e.g. apps/staging/observability/).
        path = "apps/staging"
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
