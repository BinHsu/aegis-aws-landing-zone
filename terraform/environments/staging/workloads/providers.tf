# -----------------------------------------------------------------------------
# Providers — single region per apply (ADR-032 external orchestration)
# -----------------------------------------------------------------------------
# This layer handles workloads on exactly one EKS cluster, in one region, per
# apply. The region is injected by the orchestrator as TF_VAR_region. There
# are no provider aliases and no slot pattern.
#
# helm is intentionally NOT declared: the workloads layer deploys via ArgoCD
# Applications (kubectl_manifest), not direct helm_release.
#
# The kubernetes / kubectl providers reference the cluster endpoint from the
# platform layer's (region-scoped) remote state. These providers are passed
# into ./modules/eks-workloads via its `providers = {}` block, mapping the
# layer's default providers onto the module's `<type>.this` aliases.
# -----------------------------------------------------------------------------

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}

provider "kubernetes" {
  host                   = local.cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster.cluster_name, "--region", var.region]
  }
}

provider "kubectl" {
  host                   = local.cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster.cluster_name, "--region", var.region]
  }
}
