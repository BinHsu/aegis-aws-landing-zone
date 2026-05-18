# -----------------------------------------------------------------------------
# Providers — single region per apply (ADR-032 external orchestration)
# -----------------------------------------------------------------------------
# This layer handles exactly one EKS cluster, in one region, per apply. The
# region is injected by the orchestrator as TF_VAR_region. There are no
# provider aliases and no slot pattern — the multi-region loop is external.
#
# The kubernetes / helm / kubectl providers reference module.cluster outputs.
# Terraform resolves provider configurations after module bodies evaluate, so
# the forward reference works (the same lazy-evaluation Terraform supports for
# `provider "kubernetes" { host = aws_eks_cluster.main.endpoint }`).
#
# These providers are passed into ./modules/eks-cluster via its `providers = {}`
# block, mapping the layer's default providers onto the module's `<type>.this`
# configuration aliases. The module is unchanged from the slot-pattern era —
# only the layer root collapsed from K aliased slots to one.
# -----------------------------------------------------------------------------

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}

provider "kubernetes" {
  host                   = module.cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.cluster.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.cluster.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(module.cluster.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.cluster.cluster_name, "--region", var.region]
    }
  }
}

provider "kubectl" {
  host                   = module.cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.cluster.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.cluster.cluster_name, "--region", var.region]
  }
}
