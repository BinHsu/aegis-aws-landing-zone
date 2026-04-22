terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.40"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    # kubectl provider for Grafana* CRDs + ExternalSecret CRDs — deferred
    # plan-time schema validation avoids the bootstrap trap where
    # kubernetes_manifest requires the CRD to be reachable at plan time.
    # See staging/platform for the same rationale (Incident 10).
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
    }
    # helm installs grafana-operator (primary-only, ADR-022 §Multi-region).
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    # grafana/grafana provider — ADR-022 §Auth and secret chain. Provisions
    # the Cloud Access Policy + tokens (for Alloy) and the stack-level
    # service account + token (for grafana-operator) from the one-time
    # human-created bootstrap token. v4.x line — pin the minor to catch
    # obvious resource-schema breakage via Dependabot review.
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.31"
    }
  }
}
