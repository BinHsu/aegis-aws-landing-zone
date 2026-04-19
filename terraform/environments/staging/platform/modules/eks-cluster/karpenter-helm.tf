# -----------------------------------------------------------------------------
# Karpenter controller — Helm install (per-cluster)
# -----------------------------------------------------------------------------
resource "helm_release" "karpenter" {
  provider = helm.this

  name       = "karpenter"
  namespace  = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.0.8"

  # See Incident 13 — helm creates the namespace in the same transaction;
  # Fargate then schedules the resulting pods because the namespace selector
  # matches. fargate.tf does not create the namespace.
  create_namespace = true

  values = [
    yamlencode({
      settings = {
        clusterName       = aws_eks_cluster.main.name
        clusterEndpoint   = aws_eks_cluster.main.endpoint
        interruptionQueue = aws_sqs_queue.karpenter_interruption.name
      }

      serviceAccount = {
        name = "karpenter"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.karpenter_controller.arn
        }
      }

      controller = {
        resources = {
          requests = { cpu = "250m", memory = "512Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }

      replicas = 1
    }),
  ]

  depends_on = [
    aws_eks_cluster.main,
    aws_eks_fargate_profile.karpenter,
    aws_iam_role_policy.karpenter_controller,
    # Cluster-admin via group — needed for CRD delete at teardown.
    # See Incident 18 + 21.
    kubectl_manifest.aegis_cluster_admin_binding,
  ]
}
