# -----------------------------------------------------------------------------
# Karpenter controller — Helm install
# -----------------------------------------------------------------------------
# Installs the Karpenter controller via the official OCI Helm chart. The
# chart manages the ServiceAccount, Deployment, webhooks, RBAC, and CRDs
# (NodePool, NodeClaim, EC2NodeClass) that karpenter-nodepool.tf consumes.
#
# The controller runs in the `karpenter` namespace, which is hosted on
# Fargate via the Fargate profile created in fargate.tf (PR 1). This
# breaks the chicken-and-egg bootstrap: Karpenter provisions EC2, so it
# has to run somewhere that is NOT on an EC2 node it provisions itself.
#
# Chart version is pinned. Bumping requires a PR that both updates the
# pin and verifies the release notes for breaking changes (Karpenter v1
# made several breaking changes vs v0.x; treat minor bumps as suspect).
# -----------------------------------------------------------------------------

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.0.8"

  # Ensure the namespace and Fargate profile exist before installing.
  # The Fargate profile won't match pods until after install because Helm
  # creates the Deployment in the same transaction — Kubernetes schedules
  # the pods onto Fargate once the profile's namespace selector matches.

  values = [
    yamlencode({
      # Chart settings block controls Karpenter's cluster connection.
      settings = {
        clusterName       = aws_eks_cluster.main.name
        clusterEndpoint   = aws_eks_cluster.main.endpoint
        interruptionQueue = aws_sqs_queue.karpenter_interruption.name
        # featureGates expected to stabilize further in v1.x; leave defaults.
      }

      # ServiceAccount is annotated with the IRSA role ARN. Karpenter's
      # AWS SDK calls will use temporary credentials derived from the
      # cluster's OIDC token.
      serviceAccount = {
        name = "karpenter"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.karpenter_controller.arn
        }
      }

      # Controller must tolerate scheduling on Fargate. Fargate pods do
      # not have the typical node taints, so this is a no-op in practice
      # but keeps the chart behavior explicit for reviewers.
      controller = {
        resources = {
          requests = {
            cpu    = "250m"
            memory = "512Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
      }

      # Replica count = 1 on Fargate. Karpenter's leader-election handles
      # HA when running multiple replicas on EC2, but on Fargate each
      # replica is a separate billed pod. For a lab, single replica is
      # sufficient; a production deployment would set replicas = 2 across
      # AZs (which requires EC2-backed nodes or a wider Fargate profile).
      replicas = 1
    }),
  ]

  # Explicit dependencies on upstream prerequisites. Terraform doesn't
  # infer these automatically because the Helm provider's "kubernetes
  # needs to be reachable" is a coarser check than "the Fargate profile
  # admits this namespace's pods".
  depends_on = [
    aws_eks_cluster.main,
    aws_eks_fargate_profile.karpenter,
    aws_iam_role_policy.karpenter_controller,
  ]
}
