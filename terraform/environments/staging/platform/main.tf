# -----------------------------------------------------------------------------
# Staging EKS cluster — ADR-013 + ADR-032 external-orchestration multi-region
# -----------------------------------------------------------------------------
# One EKS cluster, in the single region this apply targets (var.region). The
# multi-region fan-out is external: the orchestrator runs this layer once per
# entry in eks.staging.regions[], each with its own region-scoped state key.
#
# All cluster-specific resources (EKS, KMS, IAM, Fargate, Karpenter, OIDC,
# access-entries, CoreDNS, LB Controller, ArgoCD, Kyverno, cert-manager, ESO,
# Alloy) live inside ./modules/eks-cluster. The module is unchanged from the
# slot-pattern era — it still declares `<type>.this` configuration aliases;
# the layer simply maps its default providers onto them.
# -----------------------------------------------------------------------------

locals {
  # network outputs for this region. Null-safe: when staging/network has not
  # been applied for this region, the remote state is empty. The
  # "network_layer_applied" check in config.tf surfaces the error; these
  # try() wraps prevent a hard attribute-lookup error masking that diagnostic.
  network = data.terraform_remote_state.staging_network.outputs
}

module "cluster" {
  source = "./modules/eks-cluster"

  providers = {
    aws.this        = aws
    kubernetes.this = kubernetes
    helm.this       = helm
    kubectl.this    = kubectl
  }

  # region_key and region_name both carry the AWS region under ADR-032
  # (the slot label is gone — one cluster per region per state).
  region_key          = local.region
  region_name         = local.region
  cluster_name        = local.cluster_name
  cluster_version     = local.eks_version
  public_access_cidrs = local.public_access_cidrs
  account_id          = local.account_id
  organization_name   = local.config.organization.name
  tags                = local.tags

  vpc_id             = try(local.network.vpc_id, "")
  public_subnet_ids  = try(local.network.public_subnet_ids, [])
  private_subnet_ids = try(local.network.private_subnet_ids, [])
  availability_zones = local.zones

  ci_role_arn     = local.ci_role_arn
  github_org      = local.config.github.org
  github_app_repo = local.config.github.app_repo

  # Observability — ADR-022 (conditional on config.grafana_cloud presence)
  observability_enabled = local.observability_enabled
  primary_region        = local.primary_region
  secrets_kms_key_arn   = try(data.aws_kms_alias.secrets[0].target_key_arn, "")
  grafana_cloud         = local.grafana_cloud
}
