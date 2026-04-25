# -----------------------------------------------------------------------------
# External Secrets Operator — Helm install + ClusterSecretStore (ADR-022)
# -----------------------------------------------------------------------------
# Installed as helm_release (not an ArgoCD Application) for the same reason
# as cert-manager / Kyverno: the ClusterSecretStore kubectl_manifest in this
# file references ExternalSecret CRDs that must exist synchronously. helm
# wait=true blocks Terraform until the release reports Ready, guaranteeing
# CRD availability. See Incident 26 for the async-apply race pattern this
# avoids.
#
# ClusterSecretStore (cluster-scoped, one per cluster) declares the SSM PS
# backend with ParameterStore provider + IRSA JWT auth. Each cluster's ESO
# uses its own IRSA role (external-secrets-iam.tf); both target the PRIMARY
# region's SSM PS (per ADR-022 §Multi-region). ExternalSecret resources
# referencing this store live in the staging/observability/ layer (PR-2).
#
# Service account annotation wires IRSA: the chart creates the
# external-secrets ServiceAccount in the external-secrets namespace;
# `eks.amazonaws.com/role-arn` triggers the AWS IAM webhook to inject a
# projected service account token into ESO pods.
# -----------------------------------------------------------------------------

resource "helm_release" "external_secrets" {
  count = var.observability_enabled ? 1 : 0

  provider = helm.this

  name             = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.10.4"

  values = [
    yamlencode({
      installCRDs = true

      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.external_secrets[0].arn
        }
      }

      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { memory = "128Mi" }
      }

      webhook = {
        resources = {
          requests = { cpu = "25m", memory = "32Mi" }
          limits   = { memory = "64Mi" }
        }
      }

      certController = {
        resources = {
          requests = { cpu = "25m", memory = "32Mi" }
          limits   = { memory = "64Mi" }
        }
      }

      # ServiceMonitor auto-create disabled for the same reason as cert-manager:
      # the ServiceMonitor CRD is shipped by prometheus-operator-crds (sibling
      # file in this module) — helm_release wait=true on ESO would race with
      # CRD availability on first apply. Workloads-layer follow-up adds an
      # explicit ServiceMonitor targeting ESO's /metrics endpoint.
      serviceMonitor = {
        enabled = false
      }
    }),
  ]

  depends_on = [
    aws_eks_cluster.main,
    helm_release.karpenter,
    # LB Controller webhook must be ready before this chart's Services hit
    # admission (external-secrets, external-secrets-webhook, external-secrets-cert-controller).
    # See Incident 17 (ArgoCD fix) + Incident 33 (this race recurrence).
    helm_release.aws_lb_controller,
    kubectl_manifest.aegis_cluster_admin_binding,
  ]
}

# -----------------------------------------------------------------------------
# ClusterSecretStore — SSM PS provider, IRSA JWT auth
# -----------------------------------------------------------------------------
# Cluster-scoped (applies to ExternalSecrets in any namespace). Single store
# per cluster; primary and slave both point at primary-region SSM PS. Name is
# fixed (`aegis-ssm`) — staging/observability/ ExternalSecrets reference this
# name literally.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "cluster_secret_store" {
  count = var.observability_enabled ? 1 : 0

  provider = kubectl.this

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "aegis-ssm"
    }
    spec = {
      provider = {
        aws = {
          service = "ParameterStore"
          region  = var.primary_region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
    }
  })

  depends_on = [helm_release.external_secrets]
}
