# -----------------------------------------------------------------------------
# Provider aliases — slot pattern, K=2 per ADR-018 §3 (amended 2026-04-19)
# -----------------------------------------------------------------------------
# Two role-based slots × 4 provider types (aws, kubernetes, helm, kubectl).
# K8s-family providers live here (not inside the module) because Terraform
# rejects modules that declare their own providers AND are called with count:
#
#   > The module is a legacy module which contains its own local provider
#   > configurations, and so calls to it may not use the count, for_each,
#   > or depends_on arguments.
#
# So: the parent owns the provider blocks, passing aliased providers into each
# module invocation via `providers = { aws.this = aws.primary, ... }`. Each
# cluster's module receives its own aws / kubernetes / helm / kubectl
# providers bound to that cluster's endpoint + region.
#
# Lazy-evaluation trick: the k8s provider blocks reference
# `module.cluster_primary.cluster_endpoint`. Terraform resolves provider
# configurations after module bodies evaluate, so the output reference works
# — this is the same pattern Terraform supports for `provider "kubernetes"
# { host = aws_eks_cluster.main.endpoint }` in a flat-file layout.
#
# Slave slot fallback: when eks_regions is length 1, cluster_slave_1 has
# count=0 and exposes no outputs. The try() wraps read the primary cluster
# as a dummy so the slave's providers can still instantiate (they will be
# unused because no resource in the module has count > 0).
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
# Kubernetes / Helm / kubectl — PRIMARY slot
# -----------------------------------------------------------------------------

provider "kubernetes" {
  alias = "primary"

  host                   = module.cluster_primary.cluster_endpoint
  cluster_ca_certificate = base64decode(module.cluster_primary.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.cluster_primary.cluster_name, "--region", local.primary_eks_region.region]
  }
}

provider "helm" {
  alias = "primary"

  kubernetes {
    host                   = module.cluster_primary.cluster_endpoint
    cluster_ca_certificate = base64decode(module.cluster_primary.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.cluster_primary.cluster_name, "--region", local.primary_eks_region.region]
    }
  }
}

provider "kubectl" {
  alias = "primary"

  host                   = module.cluster_primary.cluster_endpoint
  cluster_ca_certificate = base64decode(module.cluster_primary.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.cluster_primary.cluster_name, "--region", local.primary_eks_region.region]
  }
}

# -----------------------------------------------------------------------------
# Kubernetes / Helm / kubectl — SLAVE_1 slot
# -----------------------------------------------------------------------------
# When eks_regions length is 1, module.cluster_slave_1 has count=0 so
# cluster_endpoint is inaccessible. try() falls back to the primary cluster's
# endpoint — the slot's providers are defined but no module resource uses
# them (module count=0 prunes all resources).
# -----------------------------------------------------------------------------

provider "kubernetes" {
  alias = "slave_1"

  host                   = try(module.cluster_slave_1[0].cluster_endpoint, module.cluster_primary.cluster_endpoint)
  cluster_ca_certificate = base64decode(try(module.cluster_slave_1[0].cluster_certificate_authority_data, module.cluster_primary.cluster_certificate_authority_data))

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      try(module.cluster_slave_1[0].cluster_name, module.cluster_primary.cluster_name),
      "--region",
      try(local.slave_regions[0].region, local.primary_region),
    ]
  }
}

provider "helm" {
  alias = "slave_1"

  kubernetes {
    host                   = try(module.cluster_slave_1[0].cluster_endpoint, module.cluster_primary.cluster_endpoint)
    cluster_ca_certificate = base64decode(try(module.cluster_slave_1[0].cluster_certificate_authority_data, module.cluster_primary.cluster_certificate_authority_data))

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks",
        "get-token",
        "--cluster-name",
        try(module.cluster_slave_1[0].cluster_name, module.cluster_primary.cluster_name),
        "--region",
        try(local.slave_regions[0].region, local.primary_region),
      ]
    }
  }
}

provider "kubectl" {
  alias = "slave_1"

  host                   = try(module.cluster_slave_1[0].cluster_endpoint, module.cluster_primary.cluster_endpoint)
  cluster_ca_certificate = base64decode(try(module.cluster_slave_1[0].cluster_certificate_authority_data, module.cluster_primary.cluster_certificate_authority_data))
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      try(module.cluster_slave_1[0].cluster_name, module.cluster_primary.cluster_name),
      "--region",
      try(local.slave_regions[0].region, local.primary_region),
    ]
  }
}
