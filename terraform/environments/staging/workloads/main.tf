# -----------------------------------------------------------------------------
# Workloads — ADR-032 external-orchestration multi-region
# -----------------------------------------------------------------------------
# Workloads on the single cluster this apply targets (var.region): GuardDuty
# detector, engine IRSA role, namespace, NetworkPolicies, observability App,
# Argo Rollouts App. The multi-region fan-out is external — the orchestrator
# runs this layer once per entry in eks.staging.regions[].
#
# (Kyverno + cert-manager live in the platform layer per ADR-016 — see
# Incident 26 for why.)
#
# The ./modules/eks-workloads module is unchanged from the slot-pattern era —
# it still declares `<type>.this` configuration aliases; the layer maps its
# default providers onto them.
# -----------------------------------------------------------------------------

module "workloads" {
  source = "./modules/eks-workloads"

  providers = {
    aws.this        = aws
    kubernetes.this = kubernetes
    kubectl.this    = kubectl
  }

  # region_key and region_name both carry the AWS region under ADR-032.
  region_key        = local.region
  region_name       = local.region
  cluster_name      = local.cluster.cluster_name
  oidc_provider_arn = local.cluster.oidc_provider_arn
  oidc_provider_url = local.cluster.oidc_provider_url
  tags              = local.tags
}
