# -----------------------------------------------------------------------------
# Providers — primary-only, no slot pattern (ADR-026 §Decision)
# -----------------------------------------------------------------------------
# Cognito is a single global-per-pool resource per environment. Unlike
# staging/platform and staging/workloads, this layer has no K=2 slot
# pattern — there is one pool, one app client, one domain. The kubectl
# provider points at the PRIMARY cluster only because the ExternalSecret
# is created via Terraform here (not reconciled via ArgoCD from multiple
# clusters); the slave cluster also runs ESO but its reconciler will not
# see the `cognito-config` ExternalSecret because this resource lands in
# the primary's apiserver state only. If a future amendment multiplies
# the ExternalSecret across both clusters (unlikely — the SSM PS values
# are identical, one Secret per cluster is enough), migrate to ArgoCD-
# reconciled manifests rather than adding a second kubectl provider.
#
# Same lazy-evaluation pattern as observability: provider blocks
# reference `local.clusters.primary.*` which resolves at apply time
# after the terraform_remote_state data source returns. On cold apply
# without platform applied yet, the check "platform_layer_applied" in
# config.tf surfaces a readable error.
# -----------------------------------------------------------------------------

provider "aws" {
  region = local.primary_region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}

provider "kubernetes" {
  host                   = try(local.clusters.primary.cluster_endpoint, "")
  cluster_ca_certificate = try(base64decode(local.clusters.primary.cluster_certificate_authority_data), "")

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", try(local.clusters.primary.cluster_name, ""), "--region", local.primary_region]
  }
}

provider "kubectl" {
  host                   = try(local.clusters.primary.cluster_endpoint, "")
  cluster_ca_certificate = try(base64decode(local.clusters.primary.cluster_certificate_authority_data), "")
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", try(local.clusters.primary.cluster_name, ""), "--region", local.primary_region]
  }
}
