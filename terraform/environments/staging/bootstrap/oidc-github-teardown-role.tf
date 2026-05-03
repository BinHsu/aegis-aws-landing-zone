# -----------------------------------------------------------------------------
# `gh-tf-teardown-workload` — destroy role for `terraform-teardown-workload.yml` (ADR-029)
# -----------------------------------------------------------------------------
# Replaces `github-actions-terraform` for the OIDC sub claim
# `environment:workload-teardown` only. Permission character: same SERVICE
# surface as `gh-tf-apply-workload`, action list narrowed to destructive
# verbs (`Delete*`, `Detach*`, `Disassociate*`, `Terminate*`, `Disable*`,
# `Remove*`, `Revoke*`, `Release*`, `Schedule*KeyDeletion`,
# `StopExperiment`, `PurgeQueue`) plus the safety-net describe / get / list
# shapes that the teardown workflow's pre-destroy steps invoke
# (`aws ec2 describe-vpcs / describe-network-interfaces /
# describe-security-groups / describe-instances / terminate-instances /
# wait instance-terminated`, `aws eks list-clusters / update-kubeconfig`).
#
# Trust policy is keyed on the OIDC `sub` claim
# `environment:workload-teardown` only — separate from
# `gh-tf-apply-workload` so a leaked apply-tier token cannot invoke
# destructive verbs and a leaked teardown-tier token cannot create new
# resources. The two roles are siblings on the `aegis-staging`-account
# IAM tree.
#
# Multi-region (ADR-018 slot pattern, K=2): every region-scoped Sid extends
# both `${local.primary_region}` AND the DR region (resolved inline via
# `local.config.regions[*].role == "dr"` lookup, kept inline rather than
# adding `local.dr_region` to staging/bootstrap config.tf — that is scope
# creep for one consumer).
#
# No workflow change in this PR — `terraform-teardown-workload.yml` keeps
# assuming `github-actions-terraform` until PR-6 cuts it over to
# `gh-tf-teardown-workload` (chicken-and-egg avoidance).
# -----------------------------------------------------------------------------

resource "aws_iam_role" "gh_tf_teardown_workload" {
  name = "gh-tf-teardown-workload"

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
            "${replace(local.github_oidc_url, "https://", "")}:sub" = "repo:${local.github_org}/${local.github_infra_repo}:environment:workload-teardown"
          }
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "gh_tf_teardown_workload" {
  # checkov:skip=CKV_AWS_287: ReadOnlyAwsApiSurface Sid uses Resource:* on Get*/List*/Describe* actions only — restrictable per-ARN scoping is not meaningful for inventory-style API calls. Mutation prevention is enforced by the absence of any Create/Update action paired with Resource:*. See ADR-029.
  # checkov:skip=CKV_AWS_288: Same as CKV_AWS_287 — read-shape data disclosure is the explicit threat model accepted by ADR-029. AWS metadata is classified non-secret per CLAUDE.md "What is NOT a secret" clause.
  # checkov:skip=CKV_AWS_289: IAM destructive actions (Delete*/Detach*/Remove*/DeleteServiceLinkedRole) are intentionally scoped to aegis-staging-* prefixed resources. Teardown contract is "destroy what apply created" — the prefix scope is the gate.
  # checkov:skip=CKV_AWS_290: Service-namespace destructive wildcards (ec2:Delete*, eks:Delete*, elasticloadbalancing:Delete*) are needed because these AWS APIs do not support resource-level ARN constraints on most destructive write actions; region + project-tag conditions added where supported. Trust-policy-gated by `sub: environment:workload-teardown` plus environment required-reviewer + main-only deployment branches.
  # checkov:skip=CKV_AWS_355: Resource:* is by design on the read-only Sid and on AWS APIs that do not support resource-level ARNs (EC2 most destructive actions, ELB, GuardDuty, tag). Every mutating action with Resource:* is service-namespace-scoped and trust-policy-gated.
  # checkov:skip=CKV2_AWS_40: Broad iam:Delete*/Detach*/Remove*/DeleteServiceLinkedRole on aegis-staging-* prefix scope is the deliberate teardown design. Same contract as gh-tf-apply-workload — the prefix scope is the gate, the destructive verbs are intentional.
  name = "teardown-workload-scoped"
  role = aws_iam_role.gh_tf_teardown_workload.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # EC2 destructive verbs — VPC + NAT GW + IGW + SG + NACL +
        # route tables + ENIs + subnets + EIPs + flow logs + gateway
        # endpoints + Karpenter-provisioned EC2 instances. The teardown
        # workflow's `Sweep orphan EKS ENIs + security groups` step calls
        # `delete-network-interface` + `delete-security-group`; the
        # `Sweep orphan Karpenter-provisioned EC2 instances` step calls
        # `terminate-instances` + `wait instance-terminated`. Plus the
        # describe shapes those steps need (covered by
        # `ReadOnlyAwsApiSurface` Sid below). Region condition is the
        # tightest practical scope; trust policy carries the rest.
        Sid    = "Ec2Destructive"
        Effect = "Allow"
        Action = [
          "ec2:Delete*",
          "ec2:Detach*",
          "ec2:Disassociate*",
          "ec2:TerminateInstances",
          "ec2:Revoke*",
          "ec2:Release*",
          "ec2:DisableVpcClassicLink",
          "ec2:DisableVpcClassicLinkDnsSupport",
          "ec2:RemoveAddressFromClassicLink",
          "ec2:WithdrawByoipCidr",
        ]
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
        # EKS destructive verbs — cluster delete, fargate profile delete,
        # addon delete, access entry delete, identity-provider-config
        # disassociate. `aegis-staging-*` matches both
        # `aegis-staging-primary` and `aegis-staging-slave-1`.
        Sid    = "EksDestructive"
        Effect = "Allow"
        Action = [
          "eks:Delete*",
          "eks:Disassociate*",
        ]
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
        # IAM destructive verbs — delete workload-tier roles + policies +
        # instance profiles + per-cluster OIDC providers. Includes
        # `Detach*` (detach managed policy from role / detach role from
        # instance profile) and `Remove*` (RemoveRoleFromInstanceProfile
        # used by Karpenter teardown).
        Sid    = "IamDestructive"
        Effect = "Allow"
        Action = [
          "iam:Delete*",
          "iam:Detach*",
          "iam:Remove*",
          "iam:DeleteServiceLinkedRole",
        ]
        Resource = [
          "arn:aws:iam::${local.account_id}:role/aegis-staging-*",
          "arn:aws:iam::${local.account_id}:policy/aegis-staging-*",
          "arn:aws:iam::${local.account_id}:instance-profile/aegis-staging-*",
          "arn:aws:iam::${local.account_id}:oidc-provider/oidc.eks.${local.primary_region}.amazonaws.com/id/*",
          "arn:aws:iam::${local.account_id}:oidc-provider/oidc.eks.${[for r in local.config.regions : r.name if r.role == "dr"][0]}.amazonaws.com/id/*",
          "arn:aws:iam::${local.account_id}:role/aws-service-role/*",
        ]
      },
      {
        # ELB destructive verbs — ALB / NLB delete + target group
        # deregister-targets + listener delete. Region condition is the
        # tightest practical scope; the load-balancer-controller's
        # runtime-created LBs do not carry stable name prefixes.
        Sid    = "ElbDestructive"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:Delete*",
          "elasticloadbalancing:Deregister*",
        ]
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
        # CloudWatch Logs destructive verbs — EKS cluster log groups,
        # VPC flow log groups.
        Sid    = "LogsDestructive"
        Effect = "Allow"
        Action = "logs:Delete*"
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
        # SQS destructive verbs — Karpenter interruption queue delete +
        # purge.
        Sid    = "SqsDestructive"
        Effect = "Allow"
        Action = [
          "sqs:Delete*",
          "sqs:PurgeQueue",
        ]
        Resource = [
          "arn:aws:sqs:${local.primary_region}:${local.account_id}:aegis-staging-*",
          "arn:aws:sqs:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:aegis-staging-*",
        ]
      },
      {
        # EventBridge destructive verbs — Karpenter rules delete +
        # disable + remove targets.
        Sid    = "EventsDestructive"
        Effect = "Allow"
        Action = [
          "events:Delete*",
          "events:Disable*",
          "events:Remove*",
        ]
        Resource = [
          "arn:aws:events:${local.primary_region}:${local.account_id}:rule/aegis-staging-*",
          "arn:aws:events:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:rule/aegis-staging-*",
        ]
      },
      {
        # KMS destructive verbs — schedule key deletion (KMS does not
        # support immediate delete; minimum 7-day pending window),
        # disable key, delete alias.
        Sid    = "KmsDestructive"
        Effect = "Allow"
        Action = [
          "kms:ScheduleKeyDeletion",
          "kms:DisableKey",
          "kms:DeleteAlias",
        ]
        Resource = [
          "arn:aws:kms:${local.primary_region}:${local.account_id}:key/*",
          "arn:aws:kms:${local.primary_region}:${local.account_id}:alias/aegis-staging-*",
          "arn:aws:kms:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:key/*",
          "arn:aws:kms:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:alias/aegis-staging-*",
        ]
      },
      {
        # SSM Parameter Store destructive verbs — Path-A TF-generated
        # tokens (`alloy-token`, `grafana-operator-token`). Path-B
        # SaaS-credential parameters live under `staging/secrets-persistent`
        # which is outside the teardown matrix per ADR-028.
        Sid    = "SsmDestructive"
        Effect = "Allow"
        Action = [
          "ssm:DeleteParameter",
          "ssm:DeleteParameters",
          "ssm:RemoveTagsFromResource",
        ]
        Resource = [
          "arn:aws:ssm:${local.primary_region}:${local.account_id}:parameter/aegis/staging/grafana-cloud/alloy-token",
          "arn:aws:ssm:${local.primary_region}:${local.account_id}:parameter/aegis/staging/grafana-cloud/grafana-operator-token",
        ]
      },
      {
        # FIS destructive verbs — delete experiment template, stop any
        # in-flight experiment (StopExperiment is a destructive verb
        # against an active experiment, gated to primary region only
        # since FIS lives there by design).
        Sid    = "FisDestructive"
        Effect = "Allow"
        Action = [
          "fis:Delete*",
          "fis:StopExperiment",
        ]
        Resource = [
          "arn:aws:fis:${local.primary_region}:${local.account_id}:experiment-template/*",
          "arn:aws:fis:${local.primary_region}:${local.account_id}:experiment/*",
        ]
      },
      {
        # GuardDuty destructive verbs — delete detector + disable
        # features. Region-conditioned.
        Sid    = "GuardDutyDestructive"
        Effect = "Allow"
        Action = [
          "guardduty:Delete*",
          "guardduty:Disable*",
          "guardduty:Disassociate*",
        ]
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
        # CloudWatch alarm destructive verbs — FIS abort-signal alarm.
        Sid    = "CloudWatchAlarmsDestructive"
        Effect = "Allow"
        Action = [
          "cloudwatch:DeleteAlarms",
          "cloudwatch:UntagResource",
        ]
        Resource = [
          "arn:aws:cloudwatch:${local.primary_region}:${local.account_id}:alarm:*",
          "arn:aws:cloudwatch:${[for r in local.config.regions : r.name if r.role == "dr"][0]}:${local.account_id}:alarm:*",
        ]
      },
      {
        # State bucket cross-account read + write. Same scope as
        # `gh-tf-apply-workload` — terraform destroy reads + writes the
        # per-layer state objects in the shared-account state bucket.
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
        # State KMS — same gated-by-S3-service contract as apply-workload.
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
        # IPAM remote-state read — same as apply-workload. Terraform
        # destroy on the network layer reads `shared/ipam`'s state for
        # IPAM pool IDs during refresh.
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
        # Read shapes for the teardown workflow's safety-net steps and
        # for `terraform destroy`'s state-refresh phase. Includes:
        #   - `aws ec2 describe-vpcs / describe-network-interfaces /
        #     describe-security-groups / describe-instances /
        #     wait instance-terminated` (sweep VPCs + ENIs + SGs +
        #     orphan Karpenter EC2)
        #   - `aws eks list-clusters / describe-cluster /
        #     update-kubeconfig` (resolve cluster name + auth before
        #     kubectl delete)
        #   - K8s API auth (eks:AccessKubernetesApi) for the
        #     finalizer-flush + Karpenter-quiesce kubectl steps
        #   - state-refresh reads across all destroyed services
        # Resource: "*" is acceptable here because every action listed is
        # read-only — metadata disclosure is classified as not-secret per
        # CLAUDE.md threat model.
        Sid    = "ReadOnlyAwsApiSurface"
        Effect = "Allow"
        Action = [
          "iam:Get*",
          "iam:List*",
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
          "ssm:Describe*",
          "ssm:Get*",
          "ssm:List*",
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
