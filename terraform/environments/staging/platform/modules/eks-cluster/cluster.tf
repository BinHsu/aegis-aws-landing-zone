# -----------------------------------------------------------------------------
# EKS Cluster — per ADR-013, parameterized per ADR-018
# -----------------------------------------------------------------------------
# One EKS cluster in this module invocation's region. Public + private
# endpoint per ADR-013; public endpoint restricted by public_access_cidrs
# (see docs/runbooks/002-eks-access.md for the IP-drift operational contract).
#
# Authentication mode: API (Access Entries only, no aws-auth ConfigMap).
# Access mapping is in access-entries.tf.
#
# Nodes: none here — Karpenter provisions EC2 dynamically. CoreDNS and
# Karpenter itself run on Fargate (fargate.tf) to avoid the chicken-and-egg
# bootstrap problem.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# KMS key for EKS Secrets envelope encryption
# -----------------------------------------------------------------------------
resource "aws_kms_key" "cluster_secrets" {
  provider = aws.this

  description             = "EKS Secrets envelope encryption for cluster ${var.cluster_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnableRootAccount"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })

  tags = {
    Name = "${var.cluster_name}-eks-secrets"
  }
}

resource "aws_kms_alias" "cluster_secrets" {
  provider = aws.this

  name          = "alias/${var.cluster_name}-eks-secrets"
  target_key_id = aws_kms_key.cluster_secrets.key_id
}

# -----------------------------------------------------------------------------
# KMS key for CloudWatch Logs
# -----------------------------------------------------------------------------
resource "aws_kms_key" "cluster_logs" {
  provider = aws.this

  description             = "CloudWatch Logs encryption for cluster ${var.cluster_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccount"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.region_name}.amazonaws.com" }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnEquals = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.region_name}:${var.account_id}:log-group:/aws/eks/${var.cluster_name}/cluster"
          }
        }
      },
    ]
  })

  tags = {
    Name = "${var.cluster_name}-eks-logs"
  }
}

resource "aws_kms_alias" "cluster_logs" {
  provider = aws.this

  name          = "alias/${var.cluster_name}-eks-logs"
  target_key_id = aws_kms_key.cluster_logs.key_id
}

# -----------------------------------------------------------------------------
# CloudWatch Log Group
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "cluster" {
  provider = aws.this

  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 365 # CKV_AWS_338; teardown removes the log group anyway.
  kms_key_id        = aws_kms_key.cluster_logs.arn

  tags = {
    Name = "${var.cluster_name}-eks-logs"
  }
}

# -----------------------------------------------------------------------------
# Cluster IAM role
# -----------------------------------------------------------------------------
resource "aws_iam_role" "cluster" {
  provider = aws.this

  name = "${var.cluster_name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  provider = aws.this

  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_vpc_resource_controller" {
  provider = aws.this

  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.cluster.name
}

# -----------------------------------------------------------------------------
# The cluster itself
# -----------------------------------------------------------------------------
resource "aws_eks_cluster" "main" {
  provider = aws.this

  # checkov:skip=CKV_AWS_39: Public endpoint is intentional per ADR-013 (single-operator lab, no bastion). Access is restricted to public_access_cidrs and primary auth is AWS IAM SigV4 + Kubernetes RBAC via Access Entries.
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = concat(var.public_subnet_ids, var.private_subnet_ids)
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = var.public_access_cidrs
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.cluster_secrets.arn
    }
    resources = ["secrets"]
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_iam_role_policy_attachment.cluster_vpc_resource_controller,
    aws_cloudwatch_log_group.cluster,
  ]

  tags = {
    Name = var.cluster_name
  }
}
