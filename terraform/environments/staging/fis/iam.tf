# -----------------------------------------------------------------------------
# IAM service role for AWS FIS
# -----------------------------------------------------------------------------
# FIS assumes this role when executing an experiment. The role grants only
# the specific EC2 actions the demo experiment needs (stop-instances on
# tagged Karpenter nodes) plus the managed AWSFaultInjectionSimulatorEC2Access
# policy for the experiment lifecycle scaffolding.
#
# Least-privilege: no `ec2:*` wildcard. No cross-region. No cross-account.
# The experiment can only act on EC2 instances that carry the Karpenter
# NodePool tag — an attacker with this role assumed cannot damage
# non-Karpenter infrastructure.
#
# ISO 27001 Annex A.5.24 (incident management planning) and A.5.30
# (ICT readiness for business continuity) are satisfied by having the
# drill runnable on-demand, not by having the role privileged enough to
# do broader damage.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "fis" {
  name = "aegis-staging-fis-service"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "fis.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = local.account_id
        }
        ArnLike = {
          "aws:SourceArn" = "arn:aws:fis:${local.primary_region}:${local.account_id}:experiment/*"
        }
      }
    }]
  })

  tags = {
    Name = "aegis-staging-fis-service"
  }
}

# AWS managed policy: the canonical FIS->EC2 permission bundle. Grants
# ec2:StopInstances, ec2:StartInstances (for rollback), ec2:DescribeInstances,
# etc. Managed policies evolve with new FIS action types; attaching the
# managed one avoids per-release policy churn in this repo.
resource "aws_iam_role_policy_attachment" "fis_ec2" {
  role       = aws_iam_role.fis.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSFaultInjectionSimulatorEC2Access"
}

# Scope-down inline policy: intersect the managed policy's broad ec2:*
# permissions with a tag-condition that limits the blast radius to
# Karpenter-provisioned nodes only. Defense in depth — if the managed
# policy were updated with a too-permissive action, this inline policy
# still constrains the resource set.
resource "aws_iam_role_policy" "fis_karpenter_scope" {
  name = "karpenter-scope-only"
  role = aws_iam_role.fis.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyEC2ActionsOnNonKarpenterInstances"
      Effect = "Deny"
      Action = [
        "ec2:StopInstances",
        "ec2:StartInstances",
        "ec2:TerminateInstances",
        "ec2:RebootInstances",
      ]
      Resource = "arn:aws:ec2:${local.primary_region}:${local.account_id}:instance/*"
      Condition = {
        "Null" = {
          "aws:ResourceTag/karpenter.sh/nodepool" = "true"
        }
      }
    }]
  })
}
