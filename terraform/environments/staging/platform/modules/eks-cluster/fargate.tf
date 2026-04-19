# -----------------------------------------------------------------------------
# Fargate profiles — host CoreDNS and Karpenter without EC2 (ADR-013)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "fargate_pod_execution" {
  provider = aws.this

  name = "${var.cluster_name}-fargate-pod-execution-role"

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
  provider = aws.this

  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
  role       = aws_iam_role.fargate_pod_execution.name
}

resource "aws_eks_fargate_profile" "kube_system" {
  provider = aws.this

  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "kube-system"
  pod_execution_role_arn = aws_iam_role.fargate_pod_execution.arn
  subnet_ids             = var.private_subnet_ids

  selector {
    namespace = "kube-system"
    labels = {
      "k8s-app" = "kube-dns"
    }
  }
}

resource "aws_eks_fargate_profile" "karpenter" {
  provider = aws.this

  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "karpenter"
  pod_execution_role_arn = aws_iam_role.fargate_pod_execution.arn
  subnet_ids             = var.private_subnet_ids

  selector {
    namespace = "karpenter"
  }
}
