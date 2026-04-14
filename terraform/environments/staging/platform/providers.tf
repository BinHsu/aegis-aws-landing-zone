provider "aws" {
  region = local.primary_region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}

# -----------------------------------------------------------------------------
# Kubernetes / Helm providers — authenticate to the EKS cluster via the AWS
# CLI `get-token` exec plugin. This mirrors what `aws eks update-kubeconfig`
# writes to a human operator's kubeconfig, but keeps the authentication
# dynamic: when this Terraform runs in CI under the github-actions-terraform
# role (which is mapped to cluster-admin via access-entries.tf), that is the
# identity used for Kubernetes API calls. When run locally by the operator,
# the PlatformAdmin SSO session is used.
#
# The exec block, rather than a static token, avoids storing short-lived
# credentials in the plan and keeps this configuration independent of which
# principal applies the layer.
# -----------------------------------------------------------------------------
provider "kubernetes" {
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name, "--region", local.primary_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name, "--region", local.primary_region]
    }
  }
}

# kubectl provider — used for CRD instances. Auth matches the kubernetes
# provider above. `load_config_file = false` disables the local kubeconfig
# fallback, which is important in CI where /github/home/.kube/config does
# not exist and would otherwise trigger a misleading error.
provider "kubectl" {
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name, "--region", local.primary_region]
  }
}
