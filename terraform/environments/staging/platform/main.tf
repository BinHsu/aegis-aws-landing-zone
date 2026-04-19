# -----------------------------------------------------------------------------
# Staging EKS clusters — ADR-013 + ADR-018
# -----------------------------------------------------------------------------
# One module invocation per entry in eks.staging.regions[]. Provider aliases
# follow the slot pattern (primary, slave_1). All cluster-specific resources
# (EKS, KMS, IAM, Fargate, Karpenter, OIDC, access-entries, CoreDNS,
# LB Controller, ArgoCD) live inside modules/eks-cluster/.
#
# State structure: single state per layer — all invocations share
# staging/platform/terraform.tfstate. Per ADR-018 §4.
# -----------------------------------------------------------------------------

locals {
  # Null-safe lookup — when staging/network has not yet been applied, its
  # remote state outputs are empty. The check "network_layer_applied" in
  # config.tf surfaces the error; this try() prevents a hard error on the
  # attribute lookup that would mask that check block's diagnostic message.
  vpcs = try(data.terraform_remote_state.staging_network.outputs.vpcs, {
    primary = {
      vpc_id             = ""
      public_subnet_ids  = []
      private_subnet_ids = []
    }
  })
}

module "cluster_primary" {
  source = "./modules/eks-cluster"

  providers = {
    aws.this        = aws.primary
    kubernetes.this = kubernetes.primary
    helm.this       = helm.primary
    kubectl.this    = kubectl.primary
  }

  region_key          = "primary"
  region_name         = local.primary_eks_region.region
  cluster_name        = "${local.cluster_name_base}-primary"
  cluster_version     = local.eks_version
  public_access_cidrs = local.public_access_cidrs
  account_id          = local.account_id
  organization_name   = local.config.organization.name
  tags                = local.tags

  vpc_id             = try(local.vpcs.primary.vpc_id, "")
  public_subnet_ids  = try(local.vpcs.primary.public_subnet_ids, [])
  private_subnet_ids = try(local.vpcs.primary.private_subnet_ids, [])
  availability_zones = local.zones_by_region[local.primary_eks_region.region]

  ci_role_arn     = local.ci_role_arn
  github_org      = local.config.github.org
  github_app_repo = local.config.github.app_repo
}

module "cluster_slave_1" {
  source = "./modules/eks-cluster"

  count = length(local.slave_regions) >= 1 ? 1 : 0

  providers = {
    aws.this        = aws.slave_1
    kubernetes.this = kubernetes.slave_1
    helm.this       = helm.slave_1
    kubectl.this    = kubectl.slave_1
  }

  region_key          = "slave_1"
  region_name         = try(local.slave_regions[0].region, local.primary_region)
  cluster_name        = "${local.cluster_name_base}-slave-1"
  cluster_version     = local.eks_version
  public_access_cidrs = local.public_access_cidrs
  account_id          = local.account_id
  organization_name   = local.config.organization.name
  tags                = local.tags

  vpc_id             = try(local.vpcs.slave_1.vpc_id, "")
  public_subnet_ids  = try(local.vpcs.slave_1.public_subnet_ids, [])
  private_subnet_ids = try(local.vpcs.slave_1.private_subnet_ids, [])
  availability_zones = try(local.zones_by_region[local.slave_regions[0].region], [])

  ci_role_arn     = local.ci_role_arn
  github_org      = local.config.github.org
  github_app_repo = local.config.github.app_repo
}
