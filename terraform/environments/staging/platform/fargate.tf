# -----------------------------------------------------------------------------
# Fargate profiles — host CoreDNS and Karpenter without EC2
# -----------------------------------------------------------------------------
# Per ADR-013 "Node provisioning", Karpenter itself runs on Fargate to avoid
# the bootstrap chicken-and-egg problem: Karpenter provisions EC2, so
# something has to run Karpenter before the first EC2 node exists. CoreDNS
# also runs on Fargate for the same reason (name resolution is needed before
# Karpenter can schedule anything).
#
# All other workloads land on EC2 nodes provisioned by Karpenter (Phase 3c
# follow-up PR). Fargate is NOT the default — it is used only for these two
# specific system-pod namespaces.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Fargate pod execution role
# -----------------------------------------------------------------------------
# Assumed by the Fargate control plane to pull images for the pod and write
# logs on the pod's behalf. Not the same as the pod's own IAM role (pods
# use IRSA for AWS API access).
# -----------------------------------------------------------------------------
resource "aws_iam_role" "fargate_pod_execution" {
  name = "${local.cluster_name}-fargate-pod-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks-fargate-pods.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "fargate_pod_execution" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
  role       = aws_iam_role.fargate_pod_execution.name
}

# -----------------------------------------------------------------------------
# Fargate profile: kube-system (CoreDNS)
# -----------------------------------------------------------------------------
# EKS-managed CoreDNS addon is scheduled onto Fargate when no EC2 nodes are
# available. We also need to patch the CoreDNS Deployment annotation
# `eks.amazonaws.com/compute-type: fargate` after the Karpenter PR lands so
# that CoreDNS stays on Fargate once EC2 capacity appears; that patch is
# applied in the Helm/Kubernetes layer (Phase 3c follow-up PR).
# -----------------------------------------------------------------------------
resource "aws_eks_fargate_profile" "kube_system" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "kube-system"
  pod_execution_role_arn = aws_iam_role.fargate_pod_execution.arn
  subnet_ids             = data.terraform_remote_state.staging_network.outputs.private_subnet_ids

  selector {
    namespace = "kube-system"
    labels = {
      "k8s-app" = "kube-dns"
    }
  }
}

# -----------------------------------------------------------------------------
# Fargate profile: karpenter
# -----------------------------------------------------------------------------
# The Karpenter controller itself runs in the `karpenter` namespace on
# Fargate. Workload pods never run here — only the controller (one replica,
# ~$0.04/hr on Fargate at the smallest task size).
# -----------------------------------------------------------------------------
resource "aws_eks_fargate_profile" "karpenter" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "karpenter"
  pod_execution_role_arn = aws_iam_role.fargate_pod_execution.arn
  subnet_ids             = data.terraform_remote_state.staging_network.outputs.private_subnet_ids

  selector {
    namespace = "karpenter"
  }
}
