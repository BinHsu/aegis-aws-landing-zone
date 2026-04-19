# -----------------------------------------------------------------------------
# CoreDNS — explicit EKS addon with Fargate compute type (Incident 16)
# -----------------------------------------------------------------------------
# See the pre-refactor top-level coredns-addon.tf for the full rationale.
# The short version: without this resource, EKS auto-installs CoreDNS with
# computeType=ec2, pods sit Pending forever on a Fargate-only cluster,
# DNS is down, Karpenter can't reach sts.amazonaws.com, everything hangs.
# -----------------------------------------------------------------------------

resource "aws_eks_addon" "coredns" {
  provider = aws.this

  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    computeType = "Fargate"

    resources = {
      limits = {
        cpu    = "0.25"
        memory = "512Mi"
      }
      requests = {
        cpu    = "0.25"
        memory = "512Mi"
      }
    }
  })

  depends_on = [aws_eks_fargate_profile.kube_system]
}
