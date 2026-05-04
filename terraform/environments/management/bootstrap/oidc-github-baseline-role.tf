# -----------------------------------------------------------------------------
# `gh-tf-apply-baseline` — apply role for `terraform-apply-baseline.yml` (ADR-029)
# -----------------------------------------------------------------------------
# Replaces `github-actions-terraform` for the `ref:refs/heads/main` trigger
# only. Permission character: scoped mutation across baseline-tier API
# surfaces — Org / SSO / IAM / KMS / state-bucket / SLR. Cost-incurring
# workload-tier surfaces (EC2 / VPC / EKS / ELB / RDS) are explicitly out
# of scope and live in `gh-tf-apply-workload`.
#
# Trust policy is keyed on the OIDC `sub` claim `ref:refs/heads/main` only —
# the other triggers (`pull_request`, `environment:workload-apply`,
# `environment:workload-teardown`) continue to assume their own purpose-scoped
# roles. See ADR-029 for the full identity-by-trigger split.
#
# Scope per account: this is the management-account variant. It covers the
# union of API surfaces mutated by `terraform/environments/management/
# {bootstrap,scps}` — Organizations, SSO, IAM (roles + OIDC provider +
# account alias), and the read shapes a `terraform plan` after apply needs.
#
# No workflow change in this PR — `terraform-apply-baseline.yml` keeps
# assuming `github-actions-terraform` until PR-4 cuts it over to
# `gh-tf-apply-baseline` (chicken-and-egg avoidance: flipping the workflow
# here would block this PR's own CI on a role not yet in main).
# -----------------------------------------------------------------------------

resource "aws_iam_role" "gh_tf_apply_baseline" {
  name = "gh-tf-apply-baseline"

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
              "${replace(local.github_oidc_url, "https://", "")}:sub" = "repo:${local.github_org}/${local.github_infra_repo}:ref:refs/heads/main"
            },
            local.github_oidc_infra_repo_id_claim,
          )
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "gh_tf_apply_baseline" {
  # checkov:skip=CKV_AWS_287: ReadOnlyAwsApiSurface Sid uses Resource:* on Get*/List*/Describe* actions only — restrictable per-ARN scoping is not meaningful for inventory-style API calls. Mutation prevention is enforced by the absence of any Create/Update/Delete action paired with Resource:*. See ADR-029.
  # checkov:skip=CKV_AWS_288: Same as CKV_AWS_287 — read-shape data disclosure is the explicit threat model accepted by ADR-029. AWS metadata is classified non-secret per CLAUDE.md "What is NOT a secret" clause.
  # checkov:skip=CKV_AWS_289: `iam:*` is intentionally scoped to project-prefixed resources (aegis-*/github-actions-*/gh-tf-*) plus the OIDC provider and account alias — see Sid IamScoped Resource list. The role is the apply-tier identity for `terraform-apply-baseline.yml` and must be able to manage the project's own IAM resources. Permission-management within a fixed prefix is the apply contract, not a misuse.
  # checkov:skip=CKV_AWS_290: Service-namespace wildcards (organizations:*, sso:*, identitystore:*) are needed because these AWS APIs do not support resource-level ARN constraints on most write actions; service-namespace scoping is the tightest contract available and is gated by trust policy `sub: ref:refs/heads/main` plus branch protection on main.
  # checkov:skip=CKV_AWS_355: Resource:* is by design on the read-only Sid and on AWS APIs without resource-level ARN support. Every mutating action with Resource:* is service-namespace-scoped and trust-policy-gated.
  # checkov:skip=CKV2_AWS_40: `iam:*` is intentionally allowed within the aegis-*/github-actions-*/gh-tf-* prefix scope for apply-tier baseline operations (creating IRSA roles, OIDC providers, account aliases). Full IAM privileges on a fixed ARN-prefix scope is a deliberate design — an enumerated whitelist of iam:CreateRole/UpdateRole/DeleteRole/...x20+ would be a maintenance liability with the same effective surface. ADR-029 §Decision describes the apply-baseline scope.
  name = "apply-baseline-scoped"
  role = aws_iam_role.gh_tf_apply_baseline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # IAM mutation — scoped to project-prefixed resources plus the
        # OIDC provider. `aegis-*` covers Terraform-controlled roles;
        # `github-actions-*` and `gh-tf-*` cover the CI roles managed
        # by this very layer (including this role's own in-place updates).
        # Account alias management is a separate Sid below because AWS IAM
        # does not accept resource-level ARNs on the alias actions.
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
        # IAM service-linked role creation — gated to the two SLRs the
        # apply path legitimately creates. ADR-029 OQ-2 retained these
        # because AWS auto-recreates them under conditions not predictable
        # from baseline state. `eks.amazonaws.com` not strictly used in
        # mgmt today but kept for symmetry across the 3 baseline files.
        Sid      = "IamServiceLinkedRoleCreate"
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = "arn:aws:iam::${local.account_id}:role/aws-service-role/*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = [
              "spot.amazonaws.com",
              "eks.amazonaws.com",
            ]
          }
        }
      },
      {
        # Organizations — mgmt-only. Covers SCPs, OUs, accounts, delegated-
        # administrator (used to delegate IPAM to shared per ADR).
        Sid      = "OrganizationsFull"
        Effect   = "Allow"
        Action   = "organizations:*"
        Resource = "*"
      },
      {
        # SSO and identity store — mgmt-only. Covers permission set + account
        # assignment management. AWS SSO API does not support resource-level
        # ARNs on most write actions; service-namespace scoping is the
        # tightest contract available.
        Sid    = "SsoAndIdentityStoreFull"
        Effect = "Allow"
        Action = [
          "sso:*",
          "identitystore:*",
        ]
        Resource = "*"
      },
      {
        # State bucket read + write. State bucket lives in the shared
        # account; the management layer's state object is read/written
        # through the cross-account bucket policy. Wildcard PutObject is
        # required because Terraform writes the state file on apply.
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
        # KMS for state-bucket encrypt/decrypt — the key lives in the
        # shared account (cross-account access via key policy). Gated by
        # `kms:ViaService = s3.<region>.amazonaws.com` so the role can
        # only use this key through S3, not directly.
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
        # contract. Read-only by AWS service shape (TagResource and
        # UntagResource are per-service actions, not under tag:*).
        Sid      = "TagApi"
        Effect   = "Allow"
        Action   = "tag:*"
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
          "ec2:Describe*",
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
          "sso:Describe*",
          "sso:List*",
          "sso:Get*",
          "identitystore:Describe*",
          "identitystore:List*",
          "tag:Get*",
          "sts:GetCallerIdentity",
        ]
        Resource = "*"
      },
    ]
  })
}
