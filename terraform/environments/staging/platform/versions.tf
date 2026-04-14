terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    # gavinbunney/kubectl used for CRD instances (NodePool, EC2NodeClass,
    # ArgoCD root Application). Unlike hashicorp/kubernetes's
    # `kubernetes_manifest`, this provider does NOT require the cluster to
    # be reachable at plan time (it applies raw YAML via `kubectl apply`
    # at apply time). Necessary to avoid the "first apply plan fails
    # because cluster does not exist yet" bootstrap trap.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
    }
  }
}
