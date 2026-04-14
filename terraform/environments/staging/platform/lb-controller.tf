# -----------------------------------------------------------------------------
# AWS Load Balancer Controller — Helm install
# -----------------------------------------------------------------------------
# Watches for Kubernetes Ingress and Service (type=LoadBalancer) resources
# and provisions ALBs / NLBs on AWS. Integrates with ACM for TLS, enabling
# the "public services terminate TLS at ACM, not cert-manager" pattern
# described in ADR-013 "TLS certificate provider".
#
# The controller runs in the `kube-system` namespace (AWS convention, matches
# the upstream chart default). It schedules onto whatever node capacity is
# available — Karpenter-provisioned EC2 is fine. The Fargate profile for
# kube-system (PR 1) is narrowed to CoreDNS only via the `k8s-app=kube-dns`
# label selector, so this controller does NOT land on Fargate.
# -----------------------------------------------------------------------------

resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.8.2" # tracks controller v2.8.2 — match to policy file

  values = [
    yamlencode({
      clusterName = aws_eks_cluster.main.name

      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.lb_controller.arn
        }
      }

      # Region must be explicit when running outside the cluster's default
      # region discovery path (which is fine for this project, but explicit
      # is better).
      region = local.primary_region
      vpcId  = data.terraform_remote_state.staging_network.outputs.vpc_id

      # Single replica for the lab. Controller is stateless; leader election
      # handles multi-replica HA in production (replicaCount = 2 + topology
      # spread constraints).
      replicaCount = 1

      # Resource requests keep the controller well-behaved on constrained
      # node capacity (single small Karpenter EC2 while idle).
      resources = {
        requests = {
          cpu    = "100m"
          memory = "128Mi"
        }
        limits = {
          cpu    = "200m"
          memory = "256Mi"
        }
      }
    }),
  ]

  depends_on = [
    aws_iam_role_policy.lb_controller,
    # Karpenter must be installed first so that when the controller pod
    # schedules, there is a way to provision EC2 capacity for it.
    # (If Karpenter fails, the controller pod sits Pending and the apply
    # hangs, which is actually the correct diagnostic signal.)
    helm_release.karpenter,
    # Cluster-admin binding — see cluster-role-binding.tf and Incident 21.
    kubectl_manifest.aegis_cluster_admin_binding,
  ]
}
