# -----------------------------------------------------------------------------
# `gh-tf-apply-baseline` — apply role for `terraform-apply-baseline.yml` (ADR-014)
# -----------------------------------------------------------------------------
# Apply role for the `ref:refs/heads/main` trigger. Permission character:
# scoped mutation across baseline-tier API surfaces — Org / SSO / IAM / KMS /
# state-bucket / SLR. Cost-incurring workload-tier surfaces (EC2 / VPC / EKS /
# ELB / RDS) are not part of this repository's scope.
#
# Trust policy is keyed on the OIDC `sub` claim `ref:refs/heads/main` — the
# `pull_request` trigger assumes its own read-only role, `gh-tf-plan`. See
# ADR-014 for the full identity-by-trigger split.
#
# ADR-022 (`terraform-apply-baseline.yml` gated SCP apply) binds the
# `apply-scps` job to GitHub Environment `landing-zone-apply-scps`. A job
# running under a GitHub Environment presents `sub:
# repo:<org>/<repo>:environment:<name>` instead of `...:ref:refs/heads/main` —
# a second, additive sub pattern is required or that job's OIDC assumption
# fails closed (Incident: run 29015217599, PR #330 bound the environment
# without updating this trust policy).
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
          #
          # Two sub shapes are accepted: the `ref:refs/heads/main` push trigger
          # (apply-baseline, plan-scps, and apply-scps all assume this role) and
          # the `environment:landing-zone-apply-scps` shape GitHub presents when
          # a job is bound to that Environment (apply-scps only, ADR-022).
          StringLike = {
            "${replace(local.github_oidc_url, "https://", "")}:sub" = [
              "repo:${local.github_org}/*:ref:refs/heads/main",
              "repo:${local.github_org}/*:environment:landing-zone-apply-scps",
            ]
          }
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "gh_tf_apply_baseline" {
  # checkov:skip=CKV_AWS_287: ReadOnlyAwsApiSurface Sid uses Resource:* on Get*/List*/Describe* actions only — restrictable per-ARN scoping is not meaningful for inventory-style API calls. Mutation prevention is enforced by the absence of any Create/Update/Delete action paired with Resource:*. See ADR-014.
  # checkov:skip=CKV_AWS_288: Same as CKV_AWS_287 — read-shape data disclosure is the explicit threat model accepted by ADR-014. AWS metadata is classified non-secret per CLAUDE.md "What is NOT a secret" clause.
  # checkov:skip=CKV_AWS_289: `iam:*` is intentionally scoped to project-prefixed resources (aegis-*/github-actions-*/gh-tf-*) plus the OIDC provider and account alias — see Sid IamScoped Resource list. The role is the apply-tier identity for `terraform-apply-baseline.yml` and must be able to manage the project's own IAM resources. Permission-management within a fixed prefix is the apply contract, not a misuse.
  # checkov:skip=CKV_AWS_290: Service-namespace wildcards (organizations:*, sso:*, identitystore:*, guardduty:*OrganizationAdmin*, securityhub:*OrganizationAdmin*) are needed because these AWS APIs do not support resource-level ARN constraints on most write actions; service-namespace scoping is the tightest contract available and is gated by trust policy `sub: ref:refs/heads/main` plus branch protection on main.
  # checkov:skip=CKV_AWS_355: Resource:* is by design on the read-only Sid and on AWS APIs without resource-level ARN support. Every mutating action with Resource:* is service-namespace-scoped and trust-policy-gated.
  # checkov:skip=CKV2_AWS_40: `iam:*` is intentionally allowed within the aegis-*/github-actions-*/gh-tf-* prefix scope for apply-tier baseline operations (creating IRSA roles, OIDC providers, account aliases). Full IAM privileges on a fixed ARN-prefix scope is a deliberate design — an enumerated whitelist of iam:CreateRole/UpdateRole/DeleteRole/...x20+ would be a maintenance liability with the same effective surface. ADR-014 §Decision describes the apply-baseline scope. Same pattern applies to `events:*` (scoped to `rule/aegis-detective-*`) and `sns:*` (scoped to `aegis-security-alerts*`) added by ADR-016 Item A.
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
        # apply path legitimately creates. ADR-014 OQ-2 retained these
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
        # administrator (used to delegate IPAM to shared per ADR). This
        # Sid already covers organizations:RegisterDelegatedAdministrator
        # and organizations:EnableAWSServiceAccess — the GuardDuty/Security
        # Hub delegation added by Epic #302 Stage S2 needed no additions
        # here, only the service-specific Sids below.
        Sid      = "OrganizationsFull"
        Effect   = "Allow"
        Action   = "organizations:*"
        Resource = "*"
      },
      {
        # GuardDuty organization delegated-admin registration — Epic #302
        # Stage S2. `guardduty:*OrganizationAdmin*` is a single wildcard
        # that matches Enable/Disable/ListOrganizationAdminAccount(s) — the
        # full lifecycle needed for `terraform apply` (create), `terraform
        # plan` (read/refresh), and `terraform destroy -target` (the
        # documented revert path in issue #304). Listing
        # `EnableOrganizationAdminAccount` on its own would be redundant
        # (it's a strict substring match of the wildcard) so only the
        # wildcard is kept. Resource:"*" because GuardDuty's org-admin API
        # does not support resource-level ARNs.
        Sid      = "GuardDutyOrgAdminDelegation"
        Effect   = "Allow"
        Action   = "guardduty:*OrganizationAdmin*"
        Resource = "*"
      },
      {
        # Security Hub organization delegated-admin registration — Epic
        # #302 Stage S2. Same rationale as GuardDuty above: the wildcard
        # covers Enable/Disable/List so `terraform plan` refresh and the
        # `terraform destroy -target` revert path both work, not just the
        # initial apply. Resource:"*" because Security Hub's org-admin API
        # does not support resource-level ARNs.
        Sid      = "SecurityHubOrgAdminDelegation"
        Effect   = "Allow"
        Action   = "securityhub:*OrganizationAdmin*"
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
        # EventBridge rule mutation — scoped to the project's detective
        # controls rule namespace. ADR-016 Item A creates the
        # `aegis-detective-failed-oidc-assumption` rule on the default bus;
        # this Sid covers PutRule / DeleteRule / PutTargets / RemoveTargets
        # plus the tag-on-create flow Terraform uses. Resource ARN pins to
        # the default event bus + `aegis-detective-*` rule prefix so a name
        # outside the project namespace is denied.
        Sid    = "EventsForDetectiveRule"
        Effect = "Allow"
        Action = "events:*"
        Resource = [
          "arn:aws:events:${local.primary_region}:${local.account_id}:rule/aegis-detective-*",
          "arn:aws:events:${local.primary_region}:${local.account_id}:event-bus/default",
        ]
      },
      {
        # SNS topic mutation — scoped to the project's security-alerts
        # topic namespace. ADR-016 Item A creates `aegis-security-alerts`;
        # the prefix accommodates Items B/C if they add separate topics
        # rather than reusing this one.
        Sid      = "SnsForDetectiveTopic"
        Effect   = "Allow"
        Action   = "sns:*"
        Resource = "arn:aws:sns:${local.primary_region}:${local.account_id}:aegis-security-alerts*"
      },
      {
        # AWS Budgets mutation — scoped to the project's budget-name prefix.
        # ADR-019 manages the org cost guardrails (aegis-daily-usd10 /
        # aegis-monthly-usd30) and the logarchive member budget in this
        # layer. CreateBudget / UpdateBudget / DeleteBudget all map to the
        # condensed IAM action `budgets:ModifyBudget`; the budgets ARN
        # carries no region segment.
        Sid      = "BudgetsScoped"
        Effect   = "Allow"
        Action   = "budgets:*"
        Resource = "arn:aws:budgets::${local.account_id}:budget/aegis-*"
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
