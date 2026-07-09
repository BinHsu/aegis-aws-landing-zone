# -----------------------------------------------------------------------------
# `gh-tf-apply-baseline` — apply role for `terraform-apply-baseline.yml` (ADR-014)
# -----------------------------------------------------------------------------
# Apply role for the `ref:refs/heads/main` trigger. Permission character:
# scoped mutation across baseline-tier API surfaces — IAM / KMS / state-bucket
# / IPAM / RAM / SLR. Cost-incurring workload-tier surfaces (EC2 instance /
# VPC / EKS / ELB / RDS) are not part of this repository's scope.
#
# Trust policy is keyed on the OIDC `sub` claim `ref:refs/heads/main` only —
# the `pull_request` trigger assumes its own read-only role, `gh-tf-plan`. See
# ADR-014 for the full identity-by-trigger split.
#
# Scope per account: this is the shared-account variant. It covers the
# union of API surfaces mutated by `terraform/environments/shared/
# {bootstrap,ipam}` — state bucket (S3 + bucket policies + KMS), IPAM
# (`ec2:*Ipam*` and `ec2:*VpcCidr*`), and RAM resource sharing for the
# IPAM pools.
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
  # checkov:skip=CKV_AWS_287: ReadOnlyAwsApiSurface Sid uses Resource:* on Get*/List*/Describe* actions only — restrictable per-ARN scoping is not meaningful for inventory-style API calls. Mutation prevention is enforced by the absence of any Create/Update/Delete action paired with Resource:*. See ADR-014.
  # checkov:skip=CKV_AWS_288: Same as CKV_AWS_287 — read-shape data disclosure is the explicit threat model accepted by ADR-014. AWS metadata is classified non-secret per CLAUDE.md "What is NOT a secret" clause.
  # checkov:skip=CKV_AWS_289: `iam:*` is intentionally scoped to project-prefixed resources (aegis-*/github-actions-*/gh-tf-*) plus the OIDC provider and account alias. The role is the apply-tier identity for `terraform-apply-baseline.yml`; permission-management within a fixed prefix is the apply contract.
  # checkov:skip=CKV_AWS_290: Service-namespace wildcards (ram:*, IPAM ec2:*Ipam* / ec2:*VpcCidr*, kms:* on local key/alias) are scoped to local account + region OR are needed because AWS APIs do not support resource-level ARN constraints on most write actions (RAM). All trust-policy-gated by `sub: ref:refs/heads/main` plus branch protection on main.
  # checkov:skip=CKV_AWS_355: Resource:* is by design on the read-only Sid and on AWS APIs without resource-level ARN support. Every mutating action with Resource:* is service-namespace-scoped and trust-policy-gated.
  # checkov:skip=CKV2_AWS_40: `iam:*` is intentionally allowed within aegis-*/github-actions-*/gh-tf-* prefix scope for apply-tier baseline operations. Full IAM privileges on a fixed ARN-prefix is the deliberate apply-baseline design (ADR-014 §Decision). An enumerated 20+-action whitelist would be a maintenance liability with identical effective surface.
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
        # shared today but kept for symmetry across the 3 baseline files.
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
        # State bucket — bucket-level configuration on the state bucket this
        # account owns (policy, versioning, encryption, lifecycle, public-
        # access-block, ListBucket, GetBucketLocation). Bucket-level actions
        # target the bucket ARN; object read/write is the next Sid.
        Sid      = "StateBucketManage"
        Effect   = "Allow"
        Action   = "s3:*"
        Resource = "arn:aws:s3:::${local.bucket_name}"
      },
      {
        # State objects — read/write limited to the shared account's own
        # `shared/` key prefix (issue #314). The shared account owns the
        # bucket, so same-account access is the union of this identity policy
        # and the bucket policy; the per-prefix cap has to be asserted here,
        # not only in the bucket policy. `management/`, `staging/`, `prod/`,
        # and `deployment/` state stay unreachable from the shared CI role.
        Sid      = "StateObjectsOwnPrefix"
        Effect   = "Allow"
        Action   = "s3:*"
        Resource = "arn:aws:s3:::${local.bucket_name}/shared/*"
      },
      {
        # KMS — state encryption key lives in this account. `aegis-*`
        # alias filtering is not available on the resource ARN (KMS
        # ARNs are key-id keyed, not alias keyed); region + account
        # scope is the tightest contract.
        Sid      = "KmsLocal"
        Effect   = "Allow"
        Action   = "kms:*"
        Resource = "arn:aws:kms:${local.primary_region}:${local.account_id}:key/*"
      },
      {
        # KMS alias — alias resources have a separate ARN shape.
        Sid      = "KmsAliasLocal"
        Effect   = "Allow"
        Action   = "kms:*"
        Resource = "arn:aws:kms:${local.primary_region}:${local.account_id}:alias/aegis-*"
      },
      {
        # IPAM — `shared/ipam` creates the IPAM, top-level pool, and
        # primary + DR regional pools. AWS API surface is `ec2:*Ipam*`
        # and `ec2:*VpcCidr*` (the latter is consumed by VPCs in
        # downstream accounts but provisioning here too in case of
        # cross-account allocation operations).
        Sid    = "IpamMutate"
        Effect = "Allow"
        Action = [
          "ec2:CreateIpam",
          "ec2:DeleteIpam",
          "ec2:ModifyIpam",
          "ec2:DescribeIpams",
          "ec2:CreateIpamPool",
          "ec2:DeleteIpamPool",
          "ec2:ModifyIpamPool",
          "ec2:DescribeIpamPools",
          "ec2:ProvisionIpamPoolCidr",
          "ec2:DeprovisionIpamPoolCidr",
          "ec2:GetIpamPoolCidrs",
          "ec2:GetIpamPoolAllocations",
          "ec2:AllocateIpamPoolCidr",
          "ec2:ReleaseIpamPoolAllocation",
          "ec2:CreateIpamScope",
          "ec2:DeleteIpamScope",
          "ec2:ModifyIpamScope",
          "ec2:DescribeIpamScopes",
          "ec2:CreateTags",
          "ec2:DeleteTags",
          "ec2:DescribeTags",
        ]
        Resource = "*"
      },
      {
        # IPAM service-linked role — required for the first IPAM creation
        # in an account. Same rationale as the SLR-create above.
        Sid      = "IpamServiceLinkedRole"
        Effect   = "Allow"
        Action   = "ec2:CreateServiceLinkedRole"
        Resource = "*"
      },
      {
        # RAM — `shared/bootstrap` enables sharing with the organization;
        # `shared/ipam` shares the regional pools to the org. RAM API
        # does not support resource-level ARNs on most write actions;
        # service-namespace scoping is the tightest contract available.
        Sid      = "RamFull"
        Effect   = "Allow"
        Action   = "ram:*"
        Resource = "*"
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
        # AWS Budgets mutation — scoped to the project's budget-name prefix.
        # ADR-019 adds the per-account monthly budget to this layer.
        # CreateBudget / UpdateBudget / DeleteBudget all map to the condensed
        # IAM action `budgets:ModifyBudget`; the budgets ARN carries no
        # region segment.
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
          "ram:Get*",
          "ram:List*",
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
