# -----------------------------------------------------------------------------
# `gh-tf-apply-workload` — apply role for `terraform-apply-workload.yml` (ADR-029)
# -----------------------------------------------------------------------------
# Replaces `github-actions-terraform` for the OIDC sub claim
# `environment:workload-apply` only. Permission character: scoped mutation
# across workload-tier API surfaces — EC2 / VPC / EKS / ELB / IAM (workload
# roles) / Logs / SQS / Events / KMS / SSM-read / FIS / GuardDuty / tag.
# Baseline-tier surfaces (Org / SCP / SSO / IPAM / state-bucket /
# Cognito / CloudFront / ACM / Route53 / ECR) live in `gh-tf-apply-baseline`.
#
# Trust policy is keyed on the OIDC `sub` claim
# `environment:workload-apply` only — the other triggers
# (`pull_request`, `ref:refs/heads/main`, `environment:workload-teardown`)
# continue to assume their own purpose-scoped roles. See ADR-029 for the
# full identity-by-trigger split.
#
# Scope: this role is `aegis-staging`-account only. It covers the union of
# API surfaces mutated by `terraform/environments/staging/{network,
# platform,workloads,observability,fis}` — VPC + NAT GW + flow logs (network);
# EKS clusters + Karpenter (SQS + EventBridge) + KMS + IAM cluster/IRSA roles +
# CloudWatch log groups + EKS access entries (platform); GuardDuty +
# aegis-engine IRSA + Argo Rollouts (workloads); SSM PS Path-A token writes +
# grafana-operator helm + ESO ExternalSecret manifests (observability);
# FIS experiment template + service role + abort-signal alarm (fis).
#
# Multi-region (ADR-018 slot pattern, K=2): every region-scoped Sid extends
# both `${local.primary_region}` AND the DR region (resolved inline via
# `local.config.regions[*].role == "dr"` lookup, kept inline rather than
# adding `local.dr_region` to staging/bootstrap config.tf — that is scope
# creep for one consumer).
#
# No workflow change in this PR — `terraform-apply-workload.yml` keeps
# assuming `github-actions-terraform` until PR-6 cuts it over to
# `gh-tf-apply-workload` (chicken-and-egg avoidance: flipping the workflow
# here would block this PR's own CI on a role not yet in main).
# -----------------------------------------------------------------------------

resource "aws_iam_role" "gh_tf_apply_workload" {
  name = "gh-tf-apply-workload"

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
              "${replace(local.github_oidc_url, "https://", "")}:sub" = "repo:${local.github_org}/${local.github_infra_repo}:environment:workload-apply"
            },
            local.github_oidc_infra_repo_id_claim,
          )
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "gh_tf_apply_workload" {
  # checkov:skip=CKV_AWS_287: ReadOnlyAwsApiSurface Sid uses Resource:* on Get*/List*/Describe* actions only — restrictable per-ARN scoping is not meaningful for inventory-style API calls. Mutation prevention is enforced by the absence of any Create/Update/Delete action paired with Resource:*. See ADR-029.
  # checkov:skip=CKV_AWS_288: Same as CKV_AWS_287 — read-shape data disclosure is the explicit threat model accepted by ADR-029. AWS metadata is classified non-secret per CLAUDE.md "What is NOT a secret" clause.
  # checkov:skip=CKV_AWS_289: `iam:*` is intentionally scoped to project-prefixed resources (aegis-staging-* IRSA + cluster + node + Fargate-exec roles plus matching policies). Permission-management within a fixed prefix is the apply contract for the workload-tier role.
  # checkov:skip=CKV_AWS_290: Service-namespace wildcards (ec2:*, eks:*, elasticloadbalancing:*, fis:*, guardduty:*) are needed because these AWS APIs do not support resource-level ARN constraints on most write actions (EC2 in particular); region condition + project tag condition are added where supported. Trust-policy-gated by `sub: environment:workload-apply` plus environment required-reviewer + main-only deployment branches.
  # checkov:skip=CKV_AWS_355: Resource:* is by design on the read-only Sid and on AWS APIs that do not support resource-level ARNs (EC2 most write actions, ELB, GuardDuty, tag). Every mutating action with Resource:* is service-namespace-scoped at the action prefix and gated by the trust policy `sub: environment:workload-apply`.
  # checkov:skip=CKV2_AWS_40: `iam:*` is intentionally allowed within aegis-staging-* prefix scope for apply-tier workload operations (creating IRSA roles for cluster components). Full IAM privileges on a fixed ARN-prefix is the deliberate apply-workload design (ADR-029 §Decision). An enumerated 20+-action whitelist would carry identical effective surface with maintenance liability.
  name = "apply-workload-scoped"
  role = aws_iam_role.gh_tf_apply_workload.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # EC2 + VPC + flow logs + gateway endpoints + NAT GW + IGW + SG +
        # NACL + route tables + ENIs + subnets + EIPs. EC2 does not
        # support resource-level ARN authorization on most write actions
        # (CreateVpc / CreateSubnet / CreateRouteTable / etc.); region
        # condition is the tightest practical scope. Trust policy
        # (`environment:workload-apply`) carries the rest.
        Sid      = "Ec2Vpc"
        Effect   = "Allow"
        Action   = "ec2:*"
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = [
              local.primary_region,
              [for r in local.config.regions : r.name if r.role == "dr"][0],
            ]
          }
        }
      },
      {
        # EKS clusters — `aegis-staging-*` matches both `aegis-staging-primary`
        # and `aegis-staging-slave-1` (slot pattern ADR-018, K=2). Includes
        # access entries, fargate profiles, addons, all under cluster ARN.
        Sid    = "EksClusters"
        Effect = "Allow"
        Action = "eks:*"
        Resource = [
          "arn:aws:eks:${local.primary_region}:${local.account_id}:cluster/aegis-staging-*",
          "arn:aws:eks:${local.primary_region}:${local.account_id}:fargateprofile/aegis-staging-*/*",
          "arn:aws:eks:${local.primary_region}:${local.account_id}:addon/aegis-staging-*/*",
          "arn:aws:eks:${local.primary_region}:${local.account_id}:access-entry/aegis-staging-*/*",
          "arn:aws:eks:${local.primary_region}:${local.account_id}:identityproviderconfig/aegis-staging-*/*",
          "arn:aws:eks:${local.primary_region}:${local.account_id}:nodegroup/aegis-staging-*/*",
          "arn:aws:eks:${local.primary_region}:${local.account_id}:podidentityassociation/aegis-staging-*/*",
          "arn:aws:eks:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:cluster/aegis-staging-*",
          "arn:aws:eks:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:fargateprofile/aegis-staging-*/*",
          "arn:aws:eks:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:addon/aegis-staging-*/*",
          "arn:aws:eks:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:access-entry/aegis-staging-*/*",
          "arn:aws:eks:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:identityproviderconfig/aegis-staging-*/*",
          "arn:aws:eks:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:nodegroup/aegis-staging-*/*",
          "arn:aws:eks:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:podidentityassociation/aegis-staging-*/*",
        ]
      },
      {
        # IAM mutation — scoped to workload-tier role + policy + OIDC-provider
        # ARN patterns. Covers EKS cluster role / Fargate execution role /
        # Karpenter node + controller / aws-load-balancer-controller IRSA /
        # external-secrets IRSA / aegis-engine IRSA / FIS service role —
        # all named `aegis-staging-*` (cluster-scoped name prefix +
        # role suffix). Workload-tier per-cluster OIDC providers are
        # also included since `aws_iam_openid_connect_provider.cluster`
        # is created in `staging/platform`. Instance profiles created
        # by the Karpenter controller live under `aegis-staging-*`.
        Sid    = "IamWorkloadRoles"
        Effect = "Allow"
        Action = "iam:*"
        Resource = [
          "arn:aws:iam::${local.account_id}:role/aegis-staging-*",
          "arn:aws:iam::${local.account_id}:policy/aegis-staging-*",
          "arn:aws:iam::${local.account_id}:instance-profile/aegis-staging-*",
          "arn:aws:iam::${local.account_id}:oidc-provider/oidc.eks.${local.primary_region}.amazonaws.com/id/*",
          "arn:aws:iam::${local.account_id}:oidc-provider/oidc.eks.${[for r in local.config.regions : r.name if r.role == "dr"][0]}.amazonaws.com/id/*",
        ]
      },
      {
        # IAM service-linked role creation — gated to the SLRs the
        # workload-apply path legitimately creates. `eks.amazonaws.com`
        # and `spot.amazonaws.com` are auto-recreated by AWS during EKS
        # cluster + Karpenter spot fleet provisioning (ADR-029 OQ-2).
        # `karpenter.k8s.aws` is reserved by the Karpenter v1 controller.
        # `elasticloadbalancing.amazonaws.com` is created on first ALB
        # provisioning by the load-balancer controller. `globalaccelerator`
        # is included defensively per ADR-029 §A.3 — not used in current
        # workload-tier code, but reserved for future edge-acceleration work.
        Sid      = "IamSlrCreate"
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = "arn:aws:iam::${local.account_id}:role/aws-service-role/*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = [
              "eks.amazonaws.com",
              "spot.amazonaws.com",
              "karpenter.k8s.aws",
              "elasticloadbalancing.amazonaws.com",
              "globalaccelerator.amazonaws.com",
            ]
          }
        }
      },
      {
        # ELB v1 + v2 — ALB / NLB lifecycle is owned by the
        # aws-load-balancer-controller at runtime, not by Terraform. ELB
        # API does not support resource-level authorization on most
        # mutation actions; region condition is the tightest practical scope.
        Sid      = "Elb"
        Effect   = "Allow"
        Action   = "elasticloadbalancing:*"
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = [
              local.primary_region,
              [for r in local.config.regions : r.name if r.role == "dr"][0],
            ]
          }
        }
      },
      {
        # CloudWatch Logs — EKS cluster log groups (`/aws/eks/<cluster>/cluster`),
        # plus VPC flow logs and any future workload-tier groups, all
        # tagged Project=landing-zone-lab. Resource-level ARN scoping is
        # supported on log groups; pattern matches `/aws/eks/aegis-staging-*`.
        # `*` for VPC flow log groups is constrained by region condition.
        Sid    = "Logs"
        Effect = "Allow"
        Action = "logs:*"
        Resource = [
          "arn:aws:logs:${local.primary_region}:${local.account_id}:log-group:/aws/eks/aegis-staging-*",
          "arn:aws:logs:${local.primary_region}:${local.account_id}:log-group:/aws/eks/aegis-staging-*:*",
          "arn:aws:logs:${local.primary_region}:${local.account_id}:log-group:/aws/vpc/flow-logs/aegis-staging-*",
          "arn:aws:logs:${local.primary_region}:${local.account_id}:log-group:/aws/vpc/flow-logs/aegis-staging-*:*",
          "arn:aws:logs:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:log-group:/aws/eks/aegis-staging-*",
          "arn:aws:logs:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:log-group:/aws/eks/aegis-staging-*:*",
          "arn:aws:logs:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:log-group:/aws/vpc/flow-logs/aegis-staging-*",
          "arn:aws:logs:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:log-group:/aws/vpc/flow-logs/aegis-staging-*:*",
        ]
      },
      {
        # SQS — Karpenter interruption queue
        # (`<cluster>-karpenter-interruption`). Cluster name prefix
        # `aegis-staging-*` covers both primary + slave-1.
        Sid    = "Sqs"
        Effect = "Allow"
        Action = "sqs:*"
        Resource = [
          "arn:aws:sqs:${local.primary_region}:${local.account_id}:aegis-staging-*",
          "arn:aws:sqs:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:aegis-staging-*",
        ]
      },
      {
        # EventBridge — Karpenter rules
        # (`<cluster>-karpenter-spot-interruption`,
        # `<cluster>-karpenter-scheduled-change`,
        # `<cluster>-karpenter-instance-state-change`,
        # `<cluster>-karpenter-rebalance`). Same `aegis-staging-*` cluster
        # prefix scoping. Includes targets (rules carry sub-ARNs).
        Sid    = "Events"
        Effect = "Allow"
        Action = "events:*"
        Resource = [
          "arn:aws:events:${local.primary_region}:${local.account_id}:rule/aegis-staging-*",
          "arn:aws:events:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:rule/aegis-staging-*",
        ]
      },
      {
        # KMS — workload-tier keys for EKS secrets envelope encryption
        # (`<cluster>-eks-secrets`) and CloudWatch Logs encryption
        # (`<cluster>-eks-logs`). Aliases follow `alias/aegis-staging-*`.
        # ViaService condition is intentionally NOT applied here — the
        # apply path performs raw `kms:CreateKey` / `kms:CreateAlias` /
        # `kms:PutKeyPolicy` calls that are not service-mediated.
        Sid    = "Kms"
        Effect = "Allow"
        Action = "kms:*"
        Resource = [
          "arn:aws:kms:${local.primary_region}:${local.account_id}:key/*",
          "arn:aws:kms:${local.primary_region}:${local.account_id}:alias/aegis-staging-*",
          "arn:aws:kms:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:key/*",
          "arn:aws:kms:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:alias/aegis-staging-*",
        ]
      },
      {
        # SSM Parameter Store — read-only on `/aegis/staging/*`. The
        # observability layer reads the Path-B SaaS credentials
        # (qdrant-cloud, grafana-cloud bootstrap) plus reads-back the
        # Path-A tokens it writes. Path-A writes
        # (`alloy-token`, `grafana-operator-token`) live under the
        # `SsmAegisStagingPathAWrite` Sid below — narrower action set.
        # No write here ensures baseline-tier credentials cannot be
        # mutated from the workload trigger (ADR-028 isolation).
        Sid    = "SsmRead"
        Effect = "Allow"
        Action = [
          "ssm:Describe*",
          "ssm:Get*",
          "ssm:List*",
        ]
        Resource = [
          "arn:aws:ssm:${local.primary_region}:${local.account_id}:parameter/aegis/staging/*",
          "arn:aws:ssm:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:parameter/aegis/staging/*",
        ]
      },
      {
        # SSM Parameter Store — Path-A TF-generated token writes. Two
        # specific parameters owned by `staging/observability/tokens.tf`:
        # `alloy-token` and `grafana-operator-token` (downstream tokens
        # rotated by the bootstrap-token apply). These are TF-managed
        # SecureString parameters; their lifecycle (Put / Tag / Delete)
        # is the workload-apply path's responsibility, not baseline.
        Sid    = "SsmAegisStagingPathAWrite"
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:DeleteParameter",
          "ssm:DeleteParameters",
          "ssm:AddTagsToResource",
          "ssm:RemoveTagsFromResource",
          "ssm:LabelParameterVersion",
        ]
        Resource = [
          "arn:aws:ssm:${local.primary_region}:${local.account_id}:parameter/aegis/staging/grafana-cloud/alloy-token",
          "arn:aws:ssm:${local.primary_region}:${local.account_id}:parameter/aegis/staging/grafana-cloud/grafana-operator-token",
        ]
      },
      {
        # FIS — DR drill experiment template (ADR-020). Lives in primary
        # region only by design; the DR drill targets primary EKS nodes.
        # Resource-level ARN scoping is supported on
        # experiment-template ARNs.
        Sid    = "Fis"
        Effect = "Allow"
        Action = "fis:*"
        Resource = [
          "arn:aws:fis:${local.primary_region}:${local.account_id}:experiment-template/*",
          "arn:aws:fis:${local.primary_region}:${local.account_id}:experiment/*",
          "arn:aws:fis:${local.primary_region}:${local.account_id}:action/*",
          "arn:aws:fis:${local.primary_region}:${local.account_id}:target-account-configuration/*",
        ]
      },
      {
        # GuardDuty — staging detector + EKS audit-logs / runtime feature
        # toggles. GuardDuty resource-level authorization is partial
        # (detector-id ARN supported on some actions, not on Create).
        # Region condition is the tightest practical scope.
        Sid      = "GuardDuty"
        Effect   = "Allow"
        Action   = "guardduty:*"
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = [
              local.primary_region,
              [for r in local.config.regions : r.name if r.role == "dr"][0],
            ]
          }
        }
      },
      {
        # CloudWatch metric alarms — FIS abort-signal alarm. Scoped
        # by region; no resource-level prefix scoping (alarm ARN
        # includes a customer-chosen name only).
        Sid    = "CloudWatchAlarms"
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarms",
          "cloudwatch:DescribeAlarmsForMetric",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "cloudwatch:ListTagsForResource",
          "cloudwatch:PutMetricAlarm",
          "cloudwatch:DeleteAlarms",
          "cloudwatch:TagResource",
          "cloudwatch:UntagResource",
        ]
        Resource = [
          "arn:aws:cloudwatch:${local.primary_region}:${local.account_id}:alarm:*",
          "arn:aws:cloudwatch:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:alarm:*",
        ]
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
        # State bucket cross-account read + write. State bucket lives in
        # the shared account; this account's per-layer state objects
        # (network / platform / workloads / observability / fis) are
        # read/written via cross-account bucket policy.
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
        # the role can decrypt state objects but not invoke KMS directly
        # for other purposes against the shared-account key.
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
        # IPAM remote-state read — the network layer pulls IPAM pool IDs
        # from `shared/ipam` via `terraform_remote_state`. The state
        # object access is covered by `StateBucketCrossAccount` above;
        # this Sid covers the read-only IPAM API calls Terraform performs
        # during refresh of the consuming layer.
        Sid    = "IpamRead"
        Effect = "Allow"
        Action = [
          "ec2:DescribeIpams",
          "ec2:DescribeIpamPools",
          "ec2:DescribeIpamScopes",
          "ec2:GetIpamPoolAllocations",
          "ec2:GetIpamPoolCidrs",
        ]
        Resource = "*"
      },
      {
        # Read shapes for `terraform plan` after apply (refresh + drift
        # detection) plus the helm/kubernetes provider's state-refresh
        # API calls. Resource: "*" is acceptable here because every
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
          "eks:AccessKubernetesApi",
          "kms:Describe*",
          "kms:List*",
          "kms:GetKeyRotationStatus",
          "kms:GetKeyPolicy",
          "logs:Describe*",
          "logs:List*",
          "events:Describe*",
          "events:List*",
          "sqs:Get*",
          "sqs:List*",
          "fis:Get*",
          "fis:List*",
          "guardduty:Get*",
          "guardduty:List*",
          "guardduty:Describe*",
          "elasticloadbalancing:Describe*",
          "cloudwatch:Describe*",
          "cloudwatch:Get*",
          "cloudwatch:List*",
          "s3:GetBucket*",
          "s3:ListAllMyBuckets",
          "tag:Get*",
          "sts:GetCallerIdentity",
        ]
        Resource = "*"
      },
    ]
  })
}
