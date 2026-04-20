# -----------------------------------------------------------------------------
# Provider aliases — slot pattern, K=2 per ADR-018 §3 (amended)
# -----------------------------------------------------------------------------
# Two role-based slots × 3 provider types (aws, kubernetes, kubectl).
# K8s-family providers live here (not inside the module) because Terraform
# rejects modules that declare their own providers AND are called with count
# — see staging/platform/providers.tf for the full explanation. Same pattern,
# applied to the workloads layer.
#
# helm is intentionally NOT declared: the workloads layer deploys via
# ArgoCD Applications (kubectl_manifest), not direct helm_release. Adding
# a helm provider would be dead weight.
#
# Lazy-evaluation: kubernetes/kubectl provider blocks reference
# `local.clusters.<slot>.cluster_endpoint` — resolved at apply time after
# the platform's remote_state data source returns its outputs.
#
# Slave slot fallback: when eks_regions is length 1, local.clusters has no
# `slave_1` key. try() falls back to the primary cluster's endpoint so the
# slave's providers can still instantiate (they are unused because
# module.workloads_slave_1's count is 0 — all resources pruned).
# -----------------------------------------------------------------------------

provider "aws" {
  region = local.primary_region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}

provider "aws" {
  alias  = "primary"
  region = local.primary_region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}

provider "aws" {
  alias  = "slave_1"
  region = try(local.slave_regions[0].region, local.primary_region)

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}

# -----------------------------------------------------------------------------
# Kubernetes / kubectl — PRIMARY slot
# -----------------------------------------------------------------------------

provider "kubernetes" {
  alias = "primary"

  host                   = local.clusters.primary.cluster_endpoint
  cluster_ca_certificate = base64decode(local.clusters.primary.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.clusters.primary.cluster_name, "--region", local.primary_eks_region.region]
  }
}

provider "kubectl" {
  alias = "primary"

  host                   = local.clusters.primary.cluster_endpoint
  cluster_ca_certificate = base64decode(local.clusters.primary.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.clusters.primary.cluster_name, "--region", local.primary_eks_region.region]
  }
}

# -----------------------------------------------------------------------------
# Kubernetes / kubectl — SLAVE_1 slot
# -----------------------------------------------------------------------------
# When eks_regions length is 1, local.clusters has no `slave_1` key. try()
# falls back to the primary cluster — providers are defined but unused
# (module count=0 prunes all resources).
# -----------------------------------------------------------------------------

provider "kubernetes" {
  alias = "slave_1"

  host                   = try(local.clusters.slave_1.cluster_endpoint, local.clusters.primary.cluster_endpoint)
  cluster_ca_certificate = base64decode(try(local.clusters.slave_1.cluster_certificate_authority_data, local.clusters.primary.cluster_certificate_authority_data))

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      try(local.clusters.slave_1.cluster_name, local.clusters.primary.cluster_name),
      "--region",
      try(local.slave_regions[0].region, local.primary_region),
    ]
  }
}

provider "kubectl" {
  alias = "slave_1"

  host                   = try(local.clusters.slave_1.cluster_endpoint, local.clusters.primary.cluster_endpoint)
  cluster_ca_certificate = base64decode(try(local.clusters.slave_1.cluster_certificate_authority_data, local.clusters.primary.cluster_certificate_authority_data))
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      try(local.clusters.slave_1.cluster_name, local.clusters.primary.cluster_name),
      "--region",
      try(local.slave_regions[0].region, local.primary_region),
    ]
  }
}
