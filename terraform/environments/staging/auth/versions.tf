terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.40"
    }
    # kubernetes provider is not used today (no namespace creation — the
    # `aegis` namespace is owned by staging/workloads). Declared for
    # consistency with staging/observability so a future need (e.g. a
    # Cognito-specific namespace, unlikely) does not require a provider-
    # schema bump in a follow-up PR.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    # kubectl renders the `cognito-config` ExternalSecret CRD. Same
    # rationale as staging/observability/versions.tf: kubernetes_manifest
    # needs the CRD reachable at plan time which fails on cold apply when
    # ESO's helm release has not yet installed CRDs. kubectl_manifest
    # defers schema validation to apply time.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
    }
  }
}
