# -----------------------------------------------------------------------------
# EKS Cluster — Phase 3c per ADR-013
# -----------------------------------------------------------------------------
# Single-region EKS cluster in staging. Public + private endpoint per ADR-013
# "Control plane endpoint" section. Public endpoint is restricted by
# `public_access_cidrs` (see config/landing-zone.yaml → eks.staging, and
# docs/runbooks/002-eks-access.md for the IP-drift operational contract).
#
# Authentication mode: API (Access Entries only, no aws-auth ConfigMap).
# Access mapping is in access-entries.tf.
#
# Nodes: none here — Karpenter (Phase 3c follow-up PR) provisions EC2
# dynamically. CoreDNS and Karpenter itself run on Fargate (fargate.tf) to
# avoid the chicken-and-egg bootstrap problem.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# KMS key for EKS Secrets envelope encryption (defense in depth above the
# default AWS-managed encryption of etcd).
# -----------------------------------------------------------------------------
resource "aws_kms_key" "cluster_secrets" {
  description             = "EKS Secrets envelope encryption for cluster ${local.cluster_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name = "${local.cluster_name}-eks-secrets"
  }
}

resource "aws_kms_alias" "cluster_secrets" {
  name          = "alias/${local.cluster_name}-eks-secrets"
  target_key_id = aws_kms_key.cluster_secrets.key_id
}

# -----------------------------------------------------------------------------
# KMS key for CloudWatch Logs (cluster audit / api logs).
# -----------------------------------------------------------------------------
resource "aws_kms_key" "cluster_logs" {
  description             = "CloudWatch Logs encryption for cluster ${local.cluster_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  # CloudWatch Logs needs permission to use the key for the log group it
  # writes to. This policy grants the logs service in this region to
  # encrypt/decrypt on behalf of the log group.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccount"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${local.primary_region}.amazonaws.com" }
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
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${local.primary_region}:${local.account_id}:log-group:/aws/eks/${local.cluster_name}/cluster"
          }
        }
      },
    ]
  })

  tags = {
    Name = "${local.cluster_name}-eks-logs"
  }
}

resource "aws_kms_alias" "cluster_logs" {
  name          = "alias/${local.cluster_name}-eks-logs"
  target_key_id = aws_kms_key.cluster_logs.key_id
}

# -----------------------------------------------------------------------------
# CloudWatch Log Group — pre-created so we can set retention + KMS.
# EKS will create one implicitly if this is absent, but without retention
# (logs accumulate indefinitely) and without customer-managed encryption.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = 90 # lab-appropriate; production would be 365+
  kms_key_id        = aws_kms_key.cluster_logs.arn

  tags = {
    Name = "${local.cluster_name}-eks-logs"
  }
}

# -----------------------------------------------------------------------------
# Cluster IAM role — assumed by the EKS service itself to manage the control
# plane. Distinct from node roles (nodes use NodeInstanceRole or IRSA).
# -----------------------------------------------------------------------------
resource "aws_iam_role" "cluster" {
  name = "${local.cluster_name}-eks-cluster-role"

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
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

# AmazonEKSVPCResourceController is required when using Security Groups for
# Pods (branch ENIs). Harmless to attach unconditionally.
resource "aws_iam_role_policy_attachment" "cluster_vpc_resource_controller" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.cluster.name
}

# -----------------------------------------------------------------------------
# The cluster itself
# -----------------------------------------------------------------------------
#checkov:skip=CKV_AWS_39: Public endpoint is intentional per ADR-013 (single-operator lab, no bastion). Access is restricted to public_access_cidrs (operator IP/32) and primary auth is AWS IAM SigV4 + Kubernetes RBAC via Access Entries.
resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = local.eks_version

  vpc_config {
    subnet_ids = concat(
      data.terraform_remote_state.staging_network.outputs.public_subnet_ids,
      data.terraform_remote_state.staging_network.outputs.private_subnet_ids,
    )

    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = local.public_access_cidrs
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.cluster_secrets.arn
    }
    resources = ["secrets"]
  }

  access_config {
    # API-only: all authz goes through Access Entries, not the aws-auth
    # ConfigMap. Per ADR-013 "Operator access".
    authentication_mode = "API"

    # Do NOT grant implicit cluster-admin to whoever applies this Terraform.
    # Access is explicit via aws_eks_access_entry resources in
    # access-entries.tf (the CI role and the PlatformAdmin SSO role).
    bootstrap_cluster_creator_admin_permissions = false
  }

  # All control-plane log types enabled. Cost is trivial (~$0.50/month for a
  # lab-scale cluster); having the full audit log available is valuable for
  # any future forensics and satisfies CKV_AWS_37.
  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  # Ensure IAM attachments land before the cluster creates (or else cluster
  # create may race ahead of the role having the necessary policies), and
  # ensure the log group exists before the cluster starts writing to it.
  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_iam_role_policy_attachment.cluster_vpc_resource_controller,
    aws_cloudwatch_log_group.cluster,
  ]

  tags = {
    Name = local.cluster_name
  }
}
