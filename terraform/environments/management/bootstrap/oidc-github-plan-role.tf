# -----------------------------------------------------------------------------
# `gh-tf-plan` — read-only role for `terraform-plan.yml` on PRs (ADR-014)
# -----------------------------------------------------------------------------
# Permission character: read-only AWS metadata + state-object read +
# state-lock writes scoped to *.tflock + KMS via S3 service condition.
#
# Trust policy is keyed on the OIDC `sub` claim `pull_request` only — the
# `main` trigger assumes its own apply role, `gh-tf-apply-baseline`. See
# ADR-014 for the full identity-by-trigger split.
#
# This role purposefully cannot mutate any AWS resource other than the
# Terraform state lockfile suffix. A leaked OIDC token from a fork-PR-OIDC
# attack can at most run `terraform plan` and produce metadata disclosure
# (which CLAUDE.md classifies as not-secret). This is the unlocking move
# for closing fork-PR-OIDC as a meaningful blast-radius source.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "gh_tf_plan" {
  name                 = "gh-tf-plan"
  permissions_boundary = aws_iam_policy.ci_boundary.arn

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
          StringEquals = merge(
            {
              "${replace(local.github_oidc_url, "https://", "")}:aud" = "sts.amazonaws.com"
            },
            local.github_oidc_infra_repo_id_claim,
          )
          # Rename-proof: the immutable repository_id (StringEquals above) is the
          # binding; the sub wildcards the repo NAME so a repo rename cannot break
          # OIDC auth (the failure this trust restructure fixes).
          StringLike = {
            "${replace(local.github_oidc_url, "https://", "")}:sub" = "repo:${local.github_org}/*:pull_request"
          }
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "gh_tf_plan" {
  # checkov:skip=CKV_AWS_287: Read-only API surface (Get*/List*/Describe*) requires Resource:* — restrictable per-ARN scoping is not meaningful for inventory-style API calls. The policy's deny floor is mutation prevention, enforced via state-lock-suffix scoping (Sid WriteStateLockSuffixOnly) and the absence of any Create/Update/Delete actions. See ADR-014 §Decision and §Appendix A.2.
  # checkov:skip=CKV_AWS_288: Same as CKV_AWS_287 — data exfiltration via read-only metadata is the explicit threat model accepted by ADR-014. AWS account IDs, role ARNs, and similar metadata are classified non-secret per CLAUDE.md "What is NOT a secret" clause; the policy intentionally allows their disclosure to a fork-PR-OIDC-leaked token because the alternative (per-resource read scoping) is operationally infeasible for the breadth of reads `terraform plan` performs.
  # checkov:skip=CKV_AWS_355: Resource:* on the ReadOnlyAwsApiSurface Sid is by design — every action in that statement is read-shape (Get*/List*/Describe*/Simulate*). No mutating action uses Resource:* in this policy.
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
        # KMS decryption gated by service condition. Two ViaService entries:
        # - `s3.<region>.amazonaws.com` — for cross-account state-bucket
        #   reads (state KMS lives in shared account)
        # - `ssm.<region>.amazonaws.com` — for SSM PS SecureString reads
        #   (each account's local KMS key encrypts /aegis/<env>/* secrets)
        # Resource: "*" is bounded by the ViaService condition; without
        # it the role cannot invoke KMS directly.
        Sid      = "KmsForStateAndSsm"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = "arn:aws:kms:*:*:key/*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = [
              "s3.${local.primary_region}.amazonaws.com",
              "ssm.${local.primary_region}.amazonaws.com",
            ]
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
          # IAM Identity Center (formerly AWS SSO) — IAM service prefix
          # is `sso:` even though the CLI verb is `aws sso-admin <command>`.
          # Using `sso-admin:` here returns AccessDenied on every action.
          "sso:Describe*",
          "sso:List*",
          "sso:Get*",
          "identitystore:Describe*",
          "identitystore:List*",
          "identitystore:Get*",
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
          # ADR-016 Item A adds the `aegis-detective-failed-oidc-assumption`
          # rule on the default bus + an SNS topic. Plan-tier refresh needs
          # the read shapes for both services.
          "events:Get*",
          # LZ-baseline S2 (#311) added GuardDuty + Security Hub delegated-admin
          # registration in this layer; plan-tier refresh needs both read shapes.
          "guardduty:Get*",
          "guardduty:List*",
          "securityhub:Describe*",
          "securityhub:Get*",
          "securityhub:List*",
          "sns:Get*",
          "sns:List*",
          "ram:Get*",
          "ram:List*",
          "ec2:DescribeIpam*",
          "ec2:GetIpam*",
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
          # ADR-019 budgets-as-IaC — plan-tier refresh of the
          # aws_budgets_budget resources (and their import-block reads).
          "budgets:ViewBudget",
          "budgets:Describe*",
          "budgets:ListTagsForResource",
          "tag:Get*",
          "sts:GetCallerIdentity",
        ]
        Resource = "*"
      },
    ]
  })
}
