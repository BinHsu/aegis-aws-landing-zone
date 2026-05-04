# -----------------------------------------------------------------------------
# `gh-tf-apply-baseline` — apply role for `terraform-apply-baseline.yml` (ADR-029)
# -----------------------------------------------------------------------------
# Replaces `github-actions-terraform` for the `ref:refs/heads/main` trigger
# only. Permission character: scoped mutation across baseline-tier API
# surfaces — IAM / KMS / state-bucket / Cognito / CloudFront / ACM /
# Route53 / SSM / ECR / S3 / SLR. Cost-incurring workload-tier surfaces
# (EC2 instance / VPC / EKS / ELB / RDS) are explicitly out of scope and
# live in `gh-tf-apply-workload`.
#
# Trust policy is keyed on the OIDC `sub` claim `ref:refs/heads/main` only —
# the other triggers (`pull_request`, `environment:workload-apply`,
# `environment:workload-teardown`) continue to assume their own purpose-scoped
# roles. See ADR-029 for the full identity-by-trigger split.
#
# Scope per account: this is the staging-account variant. It covers the
# union of API surfaces mutated by `terraform/environments/staging/
# {bootstrap,secrets-persistent,auth,edge}` — IAM (OIDC + roles for
# aegis-core CI), ECR (aegis-core image repo), S3 (Bazel cache + frontend
# buckets), KMS (Bazel cache key + state cross-account), SSM PS (Path-B
# SaaS credentials), Cognito (User Pool), CloudFront, ACM (us-east-1
# constraint), Route53, plus service-linked roles.
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
          StringEquals = {
            "${replace(local.github_oidc_url, "https://", "")}:aud" = "sts.amazonaws.com"
            "${replace(local.github_oidc_url, "https://", "")}:sub" = "repo:${local.github_org}/${local.github_infra_repo}:ref:refs/heads/main"
          }
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "gh_tf_apply_baseline" {
  # checkov:skip=CKV_AWS_287: ReadOnlyAwsApiSurface Sid uses Resource:* on Get*/List*/Describe* actions only — restrictable per-ARN scoping is not meaningful for inventory-style API calls. Mutation prevention is enforced by the absence of any Create/Update/Delete action paired with Resource:*. See ADR-029.
  # checkov:skip=CKV_AWS_288: Same as CKV_AWS_287 — read-shape data disclosure is the explicit threat model accepted by ADR-029. AWS metadata is classified non-secret per CLAUDE.md "What is NOT a secret" clause.
  # checkov:skip=CKV_AWS_289: `iam:*` is intentionally scoped to project-prefixed resources (aegis-*/github-actions-*/gh-tf-*) plus the OIDC provider and account alias. Permission-management within a fixed prefix is the apply contract for the staging baseline role.
  # checkov:skip=CKV_AWS_290: Service-namespace wildcards (cognito-idp:*, cloudfront:*, route53:*) are needed because these AWS APIs do not support resource-level ARN constraints on most write actions; service-namespace scoping is the tightest contract available and is gated by trust policy `sub: ref:refs/heads/main` plus branch protection on main.
  # checkov:skip=CKV_AWS_355: Resource:* is by design on the read-only Sid and on AWS APIs without resource-level ARN support. Every mutating action with Resource:* is service-namespace-scoped and trust-policy-gated.
  # checkov:skip=CKV2_AWS_40: `iam:*` is intentionally allowed within aegis-*/github-actions-*/gh-tf-* prefix scope for apply-tier baseline operations. Full IAM privileges on a fixed ARN-prefix is the deliberate apply-baseline design (ADR-029 §Decision).
  name = "apply-baseline-scoped"
  role = aws_iam_role.gh_tf_apply_baseline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # IAM mutation — scoped to project-prefixed resources plus the
        # OIDC providers and account alias. Covers aegis-* roles,
        # github-actions-* (terraform CI + aegis-core CI roles), and
        # gh-tf-* (this very layer's role family — supports in-place updates).
        Sid    = "IamScoped"
        Effect = "Allow"
        Action = "iam:*"
        Resource = [
          "arn:aws:iam::${local.account_id}:role/aegis-*",
          "arn:aws:iam::${local.account_id}:role/github-actions-*",
          "arn:aws:iam::${local.account_id}:role/gh-tf-*",
          "arn:aws:iam::${local.account_id}:policy/aegis-*",
          "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com",
          "arn:aws:iam::${local.account_id}:account-alias/*",
        ]
      },
      {
        # IAM service-linked role creation — gated to the SLRs the apply
        # path legitimately creates. ADR-029 OQ-2 retained these because
        # AWS auto-recreates them under conditions not predictable from
        # baseline state.
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
        # Local S3 buckets — Bazel cache (staging/bootstrap) + frontend
        # (staging/edge). Project-prefixed bucket-name pattern keeps the
        # surface to aegis-owned buckets only.
        Sid      = "LocalS3Project"
        Effect   = "Allow"
        Action   = "s3:*"
        Resource = "arn:aws:s3:::aegis-*"
      },
      {
        # Local KMS — keys for Bazel cache, frontend, and any per-layer
        # workload-tier KMS that baseline provisions ahead of workload
        # apply. Project-prefixed alias filtering plus account scope.
        Sid    = "LocalKms"
        Effect = "Allow"
        Action = "kms:*"
        Resource = [
          "arn:aws:kms:${local.primary_region}:${local.account_id}:key/*",
          "arn:aws:kms:${local.primary_region}:${local.account_id}:alias/aegis-*",
        ]
      },
      {
        # ECR — aegis-core image repo (staging/bootstrap creates the repo
        # shell; aegis-core CI populates it). Scoped to the aegis-core
        # repository ARN pattern.
        Sid      = "EcrAegisCoreRepo"
        Effect   = "Allow"
        Action   = "ecr:*"
        Resource = "arn:aws:ecr:${local.primary_region}:${local.account_id}:repository/aegis-*"
      },
      {
        # ECR authorization token (account-level, no resource-level ARN
        # is supported by AWS for this single action).
        Sid      = "EcrGetAuthorizationToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        # SSM Parameter Store — Path-B SaaS credentials live under
        # /aegis/staging/* (qdrant-cloud, grafana-cloud) per ADR-028.
        # Cognito SSM parameters and Path-A TF-generated tokens also
        # under the same prefix.
        Sid      = "SsmAegisPaths"
        Effect   = "Allow"
        Action   = "ssm:*"
        Resource = "arn:aws:ssm:${local.primary_region}:${local.account_id}:parameter/aegis/*"
      },
      {
        # Cognito User Pool — staging/auth provisions the pool and clients.
        # Cognito API does not support resource-level ARNs on most write
        # actions; service-namespace scoping is the tightest contract.
        Sid      = "CognitoFull"
        Effect   = "Allow"
        Action   = "cognito-idp:*"
        Resource = "*"
      },
      {
        # CloudFront — staging/edge provisions the distribution + OAC.
        # CloudFront is a global service; resource-level ARNs are not
        # broadly supported on writes.
        Sid      = "CloudFrontFull"
        Effect   = "Allow"
        Action   = "cloudfront:*"
        Resource = "*"
      },
      {
        # ACM — staging/edge provisions the cert in us-east-1 (mandatory
        # AWS constraint for CloudFront-attached certs; cannot use
        # primary_region here). The literal `us-east-1` in the resource
        # ARN is the one acknowledged region exception in this policy.
        Sid      = "AcmCloudFrontCert"
        Effect   = "Allow"
        Action   = "acm:*"
        Resource = "arn:aws:acm:us-east-1:${local.account_id}:certificate/*"
      },
      {
        # ACM read in primary region — DNS validation and cert lookups
        # for non-CloudFront uses (e.g., ALB cert in workload-apply).
        Sid    = "AcmPrimaryRegionRead"
        Effect = "Allow"
        Action = [
          "acm:Describe*",
          "acm:List*",
          "acm:Get*",
        ]
        Resource = "*"
      },
      {
        # Route53 — staging/edge owns the hosted zone for staging.
        # Hosted zone ARN includes a UUID assigned at creation; wildcard
        # is the tightest available contract here.
        Sid      = "Route53Full"
        Effect   = "Allow"
        Action   = "route53:*"
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
          "ssm:Describe*",
          "ssm:Get*",
          "ssm:List*",
          "logs:Describe*",
          "logs:List*",
          "events:Describe*",
          "events:List*",
          "sqs:Get*",
          "sqs:List*",
          "ec2:DescribeIpam*",
          "fis:Get*",
          "fis:List*",
          "cognito-idp:Describe*",
          "cognito-idp:List*",
          "cognito-idp:Get*",
          "cloudfront:Get*",
          "cloudfront:List*",
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
