# -----------------------------------------------------------------------------
# Workloads — slot pattern, one module instance per cluster slot
# -----------------------------------------------------------------------------
# Mirrors staging/platform/main.tf. Length-1 config instantiates only
# module.workloads_primary; length-2 also instantiates module.workloads_slave_1.
# Each instance gets its own provider quad (aws / kubernetes / kubectl)
# bound to that slot's region + cluster, and its own GuardDuty detector,
# IRSA role, namespace, NetworkPolicies, Kyverno App, observability App.
# -----------------------------------------------------------------------------

module "workloads_primary" {
  source = "./modules/eks-workloads"

  providers = {
    aws.this        = aws.primary
    kubernetes.this = kubernetes.primary
    kubectl.this    = kubectl.primary
  }

  region_key        = "primary"
  region_name       = local.primary_eks_region.region
  cluster_name      = local.clusters.primary.cluster_name
  oidc_provider_arn = local.clusters.primary.oidc_provider_arn
  oidc_provider_url = local.clusters.primary.oidc_provider_url
  tags              = local.tags
}

module "workloads_slave_1" {
  source = "./modules/eks-workloads"

  count = length(local.slave_regions) >= 1 ? 1 : 0

  providers = {
    aws.this        = aws.slave_1
    kubernetes.this = kubernetes.slave_1
    kubectl.this    = kubectl.slave_1
  }

  region_key        = "slave_1"
  region_name       = try(local.slave_regions[0].region, local.primary_region)
  cluster_name      = try(local.clusters.slave_1.cluster_name, "")
  oidc_provider_arn = try(local.clusters.slave_1.oidc_provider_arn, "")
  oidc_provider_url = try(local.clusters.slave_1.oidc_provider_url, "")
  tags              = local.tags
}
