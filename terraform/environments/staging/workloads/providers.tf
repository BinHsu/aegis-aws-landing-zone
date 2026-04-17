provider "aws" {
  region = local.primary_region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}

# -----------------------------------------------------------------------------
# Kubernetes provider — authenticates to the EKS cluster via the platform
# layer's remote state outputs. Used for namespace, NetworkPolicy, and any
# future K8s resources in the workloads layer.
#
# Auth model matches staging/platform/providers.tf: exec-based token
# acquisition via `aws eks get-token`. The calling principal (CI role or
# operator SSO) must be mapped to an EKS Access Entry — see
# staging/platform/access-entries.tf.
# -----------------------------------------------------------------------------
provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_ca)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", local.primary_region]
  }
}

# kubectl provider — used for ArgoCD Application CRDs. Auth matches the
# kubernetes provider above. See staging/platform/providers.tf for rationale.
provider "kubectl" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_ca)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", local.primary_region]
  }
}
