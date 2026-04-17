# -----------------------------------------------------------------------------
# IRSA skeleton — engine ServiceAccount
# -----------------------------------------------------------------------------
# Trust policy is ready; no permission policy attached yet. The actual
# permissions depend on what aegis-core's engine needs (S3 for audio,
# SQS for job queue, etc.) — those will be added in Phase 4a'' when the
# workload requirements are concrete.
#
# The gateway does not need AWS permissions — it is a gRPC proxy between
# the ALB and the engine pool. If that changes, add a second IRSA role
# following this same pattern.
#
# Per ADR-013, IRSA is the chosen mechanism for all pod → AWS API access.
# The trust policy scopes to exactly one namespace:serviceaccount pair.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "aegis_engine" {
  name = "${local.cluster_name}-aegis-engine"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = local.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:aegis:aegis-engine"
        }
      }
    }]
  })

  tags = {
    Name = "${local.cluster_name}-aegis-engine"
  }
}
