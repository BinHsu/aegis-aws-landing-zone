terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.40"
      configuration_aliases = [aws.this]
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # kubernetes / helm / kubectl are all per-cluster: the parent's providers.tf
    # declares alias blocks (kubernetes.primary, kubernetes.slave_1, etc.),
    # and each module invocation receives them via the `providers = {}` block.
    # Declared as configuration_aliases here so the module can reference
    # `<type>.this` on every resource.
    helm = {
      source                = "hashicorp/helm"
      version               = "~> 2.17"
      configuration_aliases = [helm.this]
    }
    kubernetes = {
      source                = "hashicorp/kubernetes"
      version               = "~> 2.35"
      configuration_aliases = [kubernetes.this]
    }
    kubectl = {
      source                = "gavinbunney/kubectl"
      version               = "~> 1.19"
      configuration_aliases = [kubectl.this]
    }
  }
}
