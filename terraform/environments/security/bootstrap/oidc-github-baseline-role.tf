# -----------------------------------------------------------------------------
# `gh-tf-apply-baseline` — apply role for `terraform-apply-baseline.yml` (ADR-014)
# -----------------------------------------------------------------------------
# Apply role for the `ref:refs/heads/main` trigger. The `pull_request` trigger
# assumes its own read-only role, `gh-tf-plan`. These two are the only CI roles.
#
# Scope: the security account's landing-zone Terraform is `security/bootstrap`
# (account alias, GitHub OIDC provider, gh-tf-* / aegis-emergency-* roles) plus
# the `security/detective` layer (epic #302 D5). The permission policy below is
# IAM-on-project-prefixes + account alias + cross-account Terraform state +
# the detective-service surface.
#
# Scope note (LZ-baseline S3/S4, #305/#306 — supersedes the S1 note): the
# DetectiveServicesAdmin Sid grants guardduty:* + securityhub:* so this role
# can apply the security/detective layer (delegated-admin org configuration,
# detector, FSBP subscription). Both namespaces are inside the ADR-020
# boundary ceiling. `config:Describe*` (read-only CT-aggregator check) is
# also granted but currently sits OUTSIDE the boundary ceiling — the check
# degrades to a warning in CI until the org-uniform boundary adds the
# `config` namespace (see ADR-023).
# -----------------------------------------------------------------------------

resource "aws_iam_role" "gh_tf_apply_baseline" {
  name                 = "gh-tf-apply-baseline"
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
            "${replace(local.github_oidc_url, "https://", "")}:sub" = "repo:${local.github_org}/*:ref:refs/heads/main"
          }
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "gh_tf_apply_baseline" {
  # checkov:skip=CKV_AWS_287: ReadOnlyAwsApiSurface Sid uses Resource:* on Get*/List*/Simulate* actions only — restrictable per-ARN scoping is not meaningful for inventory-style API calls. Mutation prevention is enforced by the absence of any Create/Update/Delete action paired with Resource:*. See ADR-014.
  # checkov:skip=CKV_AWS_288: Same as CKV_AWS_287 — read-shape data disclosure is the explicit threat model accepted by ADR-014. AWS metadata is classified non-secret per CLAUDE.md "What is NOT a secret" clause.
  # checkov:skip=CKV_AWS_289: `iam:*` is intentionally scoped to project-prefixed resources (aegis-*/github-actions-*/gh-tf-*) plus the OIDC provider and account alias. Permission-management within a fixed prefix is the apply contract for the security baseline role.
  # checkov:skip=CKV_AWS_290: Service-namespace wildcards (`tag:*`, and `guardduty:*`/`securityhub:*` for the delegated-admin detective layer) are needed because these APIs create-then-reference their ARNs (or, for tagging, reject resource-level ARN constraints on writes); service-namespace scoping is the tightest contract available and is gated by trust policy `sub: ref:refs/heads/main` plus branch protection on main.
  # checkov:skip=CKV_AWS_355: Resource:* is by design on the read-only Sid and on the account-alias actions (AWS rejects resource-level ARNs there). Every mutating action with Resource:* (tag/guardduty/securityhub) is service-namespace-scoped and trust-policy-gated.
  # checkov:skip=CKV2_AWS_40: `iam:*` is intentionally allowed within aegis-*/github-actions-*/gh-tf-* prefix scope for apply-tier baseline operations. Full IAM privileges on a fixed ARN-prefix is the deliberate apply-baseline design (ADR-014 §Decision).
  name = "apply-baseline-scoped"
  role = aws_iam_role.gh_tf_apply_baseline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # IAM mutation — scoped to project-prefixed resources plus the
        # OIDC provider. Covers aegis-* roles, github-actions-* (terraform CI
        # roles), and gh-tf-* (this very layer's role family — supports
        # in-place updates). Account alias management is a separate Sid
        # below because AWS IAM does not accept resource-level ARNs on the
        # alias actions.
        Sid    = "IamScoped"
        Effect = "Allow"
        Action = "iam:*"
        Resource = [
          "arn:aws:iam::${local.account_id}:role/aegis-*",
          "arn:aws:iam::${local.account_id}:role/github-actions-*",
          "arn:aws:iam::${local.account_id}:role/gh-tf-*",
          "arn:aws:iam::${local.account_id}:policy/aegis-*",
          "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com",
        ]
      },
      {
        # Account alias — account-level operations. AWS IAM rejects any
        # resource-level ARN on these actions ("account-alias/*" is NOT
        # in the IAM-allowed-resource-path list); Resource: "*" is the
        # only accepted shape. The trust policy `sub: ref:refs/heads/main`
        # plus branch protection on main is the gate; the action set is
        # narrowed to alias-only verbs (no other iam:* leaks through).
        Sid    = "AccountAliasManagement"
        Effect = "Allow"
        Action = [
          "iam:CreateAccountAlias",
          "iam:DeleteAccountAlias",
          "iam:ListAccountAliases",
        ]
        Resource = "*"
      },
      {
        # State bucket cross-account read + write. State bucket lives in
        # the shared account; this account's state object is read/written
        # via cross-account bucket policy.
        Sid    = "StateBucketCrossAccount"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketVersioning",
        ]
        Resource = [
          "arn:aws:s3:::${local.config.organization.name}-terraform-state-${local.config.accounts.shared.id}",
          "arn:aws:s3:::${local.config.organization.name}-terraform-state-${local.config.accounts.shared.id}/*",
        ]
      },
      {
        # State KMS — key lives in shared. Gated to S3 service usage so
        # the role can decrypt state objects but not invoke KMS directly.
        Sid    = "StateKmsViaS3Only"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = "arn:aws:kms:${local.primary_region}:${local.config.accounts.shared.id}:key/*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "s3.${local.primary_region}.amazonaws.com"
          }
        }
      },
      {
        # Universal tagging — no service supports `tag:*` with a
        # resource-level ARN; service-namespace scoping is the tightest
        # contract.
        Sid      = "TagApi"
        Effect   = "Allow"
        Action   = "tag:*"
        Resource = "*"
      },
      {
        # Detective layer (S3/S4, #305/#306): this account is the org
        # delegated administrator for GuardDuty + Security Hub (S2, PR #311)
        # and owns the security/detective Terraform layer. Service-namespace
        # wildcards mirror the tag:* contract above: GuardDuty detector /
        # org-configuration and Security Hub hub / standards ARNs are
        # created-then-referenced by Terraform, so per-ARN scoping would
        # break the create path; the trust policy `sub: ref:refs/heads/main`
        # plus branch protection is the gate, and the ADR-020 boundary
        # ceiling already carries both namespaces.
        Sid    = "DetectiveServicesAdmin"
        Effect = "Allow"
        Action = [
          "guardduty:*",
          "securityhub:*",
        ]
        Resource = "*"
      },
      {
        # Read shapes for `terraform plan` after apply (refresh + drift
        # detection). Resource: "*" is acceptable here because every
        # action listed is read-only — metadata disclosure is classified
        # as not-secret per CLAUDE.md threat model.
        Sid    = "ReadOnlyAwsApiSurface"
        Effect = "Allow"
        Action = [
          "iam:Get*",
          "iam:List*",
          "iam:SimulatePrincipalPolicy",
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
          # Read-only CT Config-aggregator check (security/detective layer,
          # #306). Outside the ADR-020 boundary ceiling today — see header.
          "config:Describe*",
          "tag:Get*",
          "sts:GetCallerIdentity",
        ]
        Resource = "*"
      },
    ]
  })
}
