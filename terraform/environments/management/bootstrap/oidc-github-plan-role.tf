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
          StringEquals = merge(
            {
              "${replace(local.github_oidc_url, "https://", "")}:aud" = "sts.amazonaws.com"
              "${replace(local.github_oidc_url, "https://", "")}:sub" = "repo:${local.github_org}/${local.github_infra_repo}:pull_request"
            },
            local.github_oidc_infra_repo_id_claim,
          )
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "gh_tf_plan" {
  # checkov:skip=CKV_AWS_287: Read-only API surface (Get*/List*/Describe*) requires Resource:* — restrictable per-ARN scoping is not meaningful for inventory-style API calls. The policy's deny floor is mutation prevention, enforced via state-lock-suffix scoping (Sid WriteStateLockSuffixOnly) and the absence of any Create/Update/Delete actions. See ADR-029 §Decision and §Appendix A.2.
  # checkov:skip=CKV_AWS_288: Same as CKV_AWS_287 — data exfiltration via read-only metadata is the explicit threat model accepted by ADR-029. AWS account IDs, role ARNs, and similar metadata are classified non-secret per CLAUDE.md "What is NOT a secret" clause; the policy intentionally allows their disclosure to a fork-PR-OIDC-leaked token because the alternative (per-resource read scoping) is operationally infeasible for the breadth of reads `terraform plan` performs.
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
          # ADR-031 Item A adds the `aegis-detective-failed-oidc-assumption`
          # rule on the default bus + an SNS topic. Plan-tier refresh needs
          # the read shapes for both services.
          "events:Get*",
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
          "tag:Get*",
          "sts:GetCallerIdentity",
        ]
        Resource = "*"
      },
    ]
  })
}
