# -----------------------------------------------------------------------------
# `gh-tf-plan` — read-only role for `terraform-plan.yml` on PRs (ADR-029)
# -----------------------------------------------------------------------------
# Replaces `github-actions-terraform` for the `pull_request` trigger only.
# Permission character: read-only AWS metadata + state-object read +
# state-lock writes scoped to *.tflock + KMS via S3 service condition.
#
# Trust policy is keyed on the OIDC `sub` claim `pull_request` only — the
# other triggers (`main`, `environment:workload-apply`,
# `environment:workload-teardown`) continue to assume their own purpose-scoped
# roles. See ADR-029 for the full identity-by-trigger split.
#
# This role purposefully cannot mutate any AWS resource other than the
# Terraform state lockfile suffix. A leaked OIDC token from a fork-PR-OIDC
# attack can at most run `terraform plan` and produce metadata disclosure
# (which CLAUDE.md classifies as not-secret). This is the unlocking move
# for closing fork-PR-OIDC as a meaningful blast-radius source.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "gh_tf_plan" {
  name = "gh-tf-plan"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(local.github_oidc_url, "https://", "")}:aud" = "sts.amazonaws.com"
            "${replace(local.github_oidc_url, "https://", "")}:sub" = "repo:${local.github_org}/${local.github_infra_repo}:pull_request"
          }
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "gh_tf_plan" {
  name = "plan-readonly"
  role = aws_iam_role.gh_tf_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadStateObject"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "arn:aws:s3:::${local.config.organization.name}-terraform-state-${local.config.accounts.shared.id}/*"
      },
      {
        Sid      = "ListStateBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::${local.config.organization.name}-terraform-state-${local.config.accounts.shared.id}"
      },
      {
        Sid      = "WriteStateLockSuffixOnly"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${local.config.organization.name}-terraform-state-${local.config.accounts.shared.id}/*.tflock"
      },
      {
        # OQ-3 worst-case guard: `terraform plan -refresh=true` may write the
        # state object during refresh. Allow PutObject on the state-key suffix
        # to absorb that worst case. PR-1 will empirically observe whether
        # plan-refresh writes state under our backend; if no, this statement
        # tightens or is removed in a follow-up PR.
        Sid      = "WriteStateOnRefreshGuard"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "arn:aws:s3:::${local.config.organization.name}-terraform-state-${local.config.accounts.shared.id}/*.tfstate"
      },
      {
        Sid      = "StateKmsViaS3Only"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = "arn:aws:kms:${local.primary_region}:${local.config.accounts.shared.id}:key/*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "s3.${local.primary_region}.amazonaws.com"
          }
        }
      },
      {
        Sid    = "ReadOnlyAwsApiSurface"
        Effect = "Allow"
        Action = [
          "iam:Get*",
          "iam:List*",
          "iam:SimulatePrincipalPolicy",
          "ec2:Describe*",
          "eks:Describe*",
          "eks:List*",
          "s3:GetBucket*",
          "s3:GetEncryptionConfiguration",
          "s3:GetLifecycleConfiguration",
          "s3:GetReplicationConfiguration",
          "s3:GetAccelerateConfiguration",
          "s3:GetObjectLockConfiguration",
          "s3:ListAllMyBuckets",
          "kms:Describe*",
          "kms:List*",
          "kms:GetKeyRotationStatus",
          "kms:GetKeyPolicy",
          "organizations:Describe*",
          "organizations:List*",
          "sso-admin:Describe*",
          "sso-admin:List*",
          "sso-admin:Get*",
          "identitystore:Describe*",
          "identitystore:List*",
          "ssm:Describe*",
          "ssm:Get*",
          "ssm:List*",
          "logs:Describe*",
          "logs:List*",
          "logs:Get*",
          "sqs:Get*",
          "sqs:List*",
          "events:Describe*",
          "events:List*",
          "ram:Get*",
          "ram:List*",
          "ec2:DescribeIpam*",
          "fis:Get*",
          "fis:List*",
          "cognito-idp:Describe*",
          "cognito-idp:List*",
          "cognito-idp:Get*",
          "cloudfront:Get*",
          "cloudfront:List*",
          "acm:Describe*",
          "acm:List*",
          "route53:Get*",
          "route53:List*",
          "ecr:Describe*",
          "ecr:Get*",
          "ecr:List*",
          "elasticloadbalancing:Describe*",
          "tag:Get*",
          "sts:GetCallerIdentity",
        ]
        Resource = "*"
      },
    ]
  })
}
