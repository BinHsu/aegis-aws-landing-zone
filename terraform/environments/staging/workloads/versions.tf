terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    # kubectl provider for ArgoCD Application CRDs — deferred plan-time
    # schema validation avoids the bootstrap trap where kubernetes_manifest
    # requires the CRD to be reachable at plan time. See
    # staging/platform/karpenter-nodepool.tf and Incident 10.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
