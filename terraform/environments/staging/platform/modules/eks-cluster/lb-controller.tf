# -----------------------------------------------------------------------------
# AWS Load Balancer Controller — Helm install (per-cluster)
# -----------------------------------------------------------------------------
resource "helm_release" "aws_lb_controller" {
  provider = helm.this

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

      # Explicit region + vpcId vs auto-discovery — CI-friendly, no IMDS reliance.
      region = var.region_name
      vpcId  = var.vpc_id

      replicaCount = 1

      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "200m", memory = "256Mi" }
      }
    }),
  ]

  depends_on = [
    aws_iam_role_policy.lb_controller,
    helm_release.karpenter,
    kubectl_manifest.aegis_cluster_admin_binding,
  ]
}
