# -----------------------------------------------------------------------------
# `aegis-emergency-break-glass` — break-glass recovery role (ADR-030 OQ-1)
# -----------------------------------------------------------------------------
# Materializes the `aegis-emergency-*` namespace reserved by ADR-030's SCP
# allow-list (`deny-iam-privilege-escalation`). The role exists so the
# operator's PlatformAdmin SSO session has a documented assume-target during
# break-glass recovery — i.e., the kind of recovery driven by Incident 36,
# where the operator's SSO role itself is intentionally NOT in the SCP
# allow-list and a TF-managed policy bug requires a manual `iam:put-role-policy`
# to unstick `terraform apply`.
#
# The recovery shape that motivates this role:
#   1. Apply-tier role (`gh-tf-apply-baseline`) gets a buggy policy via TF.
#   2. CI fails because the buggy policy denies the very action the next
#      `terraform apply` needs to mutate the policy back.
#   3. Operator's SSO role is not in the SCP allow-list (intentional —
#      humans don't bypass IAM-mutation guardrails by default).
#   4. Operator assumes `aegis-emergency-break-glass`, runs the manual
#      `aws iam put-role-policy` to fix the apply role, exits the role.
#   5. CI is unblocked. Total session time: minutes.
#
# Trust policy: any session of the local-account PlatformAdmin SSO role.
# IAM Identity Center materializes a reserved role per account named
# `AWSReservedSSO_PlatformAdmin_<hash>` where the hash is account-specific
# and stable. The trust uses `ArnLike` to match the wildcard hash; the
# `Principal: { AWS = "...:root" }` clause is the standard "any IAM
# principal in this account that ALSO satisfies the Condition" pattern.
#
# Permission policy: see `aws_iam_role_policy.aegis_emergency_break_glass`
# below. The mgmt variant carries the full diagnosis surface (Org / SSO /
# IAM / KMS / SSM PS) — Org and SSO live in mgmt, so this is where SCP
# detach-and-reattach during recovery happens.
#
# Session is time-bounded to 1 hour (`max_session_duration = 3600`). Operator
# can re-assume if the recovery takes longer; the bound is the discipline
# signal that break-glass is not a working mode.
#
# SCP interaction: `aegis-emergency-break-glass` matches `aegis-emergency-*`
# in ADR-030's `deny-iam-privilege-escalation` SCP allow-list. No SCP change
# is required by this PR.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "aegis_emergency_break_glass" {
  name                 = "aegis-emergency-break-glass"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OperatorViaPlatformAdminSso"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          ArnLike = {
            "aws:PrincipalArn" = "arn:aws:iam::${local.account_id}:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_PlatformAdmin_*"
          }
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "aegis_emergency_break_glass" {
  # checkov:skip=CKV_AWS_287: Read-shape Sids (IamReadAll, OrganizationsRead, SsoRead, KmsReadAndDecrypt's Describe/List/Get verbs, StsAndTagRead) intentionally use Resource:* for inventory access during break-glass diagnosis. Mutation surface is in IamMutationOnProjectRoles + OrganizationsScpManage + SsmReadProject's mutating verbs (none — read only), all scoped or trust-policy-gated. ADR-030 OQ-1.
  # checkov:skip=CKV_AWS_288: Same as 287 — break-glass requires broad read for diagnosis; mutations are scoped. Read-shape data disclosure is the explicit threat model accepted by ADR-030.
  # checkov:skip=CKV_AWS_289: iam:* is intentionally allowed but scoped to aegis-*/gh-tf-*/github-actions-* prefixes. Permission-management within fixed prefixes is the break-glass contract — the role exists precisely to fix bad policies on those role families.
  # checkov:skip=CKV_AWS_290: organizations:* / sso:* / identitystore:* require Resource:* because the AWS APIs do not support resource-level ARN constraints. Trust policy (PlatformAdmin SSO only) is the gate.
  # checkov:skip=CKV_AWS_355: Resource:* is by design on the read-only Sids and on AWS APIs without resource-level ARN support.
  # checkov:skip=CKV2_AWS_40: iam:* on a fixed ARN-prefix scope is the deliberate break-glass design (ADR-030 OQ-1 graduation).
  name = "emergency-break-glass-scoped"
  role = aws_iam_role.aegis_emergency_break_glass.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Scoped IAM mutation — the primary break-glass primitive. Covers
        # the role/policy families that TF-managed CI roles live under.
        # When a buggy `aws_iam_role_policy` denies the action that would
        # let `terraform apply` mutate it back, this is the manual exit.
        Sid    = "IamMutationOnProjectRoles"
        Effect = "Allow"
        Action = "iam:*"
        Resource = [
          "arn:aws:iam::${local.account_id}:role/aegis-*",
          "arn:aws:iam::${local.account_id}:role/gh-tf-*",
          "arn:aws:iam::${local.account_id}:role/github-actions-*",
          "arn:aws:iam::${local.account_id}:policy/aegis-*",
        ]
      },
      {
        # IAM read across the account. Diagnosis needs to enumerate every
        # role / policy / attachment to find the bad state; mutations are
        # bounded by IamMutationOnProjectRoles above.
        Sid    = "IamReadAll"
        Effect = "Allow"
        Action = [
          "iam:Get*",
          "iam:List*",
          "iam:Simulate*",
        ]
        Resource = "*"
      },
      {
        # Organizations read — mgmt-only. For diagnosing SCP propagation
        # issues during recovery (e.g., "is the SCP currently attached?
        # which target?"). No write power here; OrganizationsScpManage
        # below carries the SCP-detach-and-reattach verbs.
        Sid    = "OrganizationsRead"
        Effect = "Allow"
        Action = [
          "organizations:Describe*",
          "organizations:List*",
        ]
        Resource = "*"
      },
      {
        # SCP detach / attach / update — the verbs needed to execute the
        # SCP-propagation-recovery pattern from Incident 36 (detach SCP,
        # wait ~30s for propagation, run the fix, reattach). Resource:*
        # because Organizations APIs do not support resource-level ARNs;
        # the trust policy (PlatformAdmin SSO only) is the gate.
        Sid    = "OrganizationsScpManage"
        Effect = "Allow"
        Action = [
          "organizations:DetachPolicy",
          "organizations:AttachPolicy",
          "organizations:UpdatePolicy",
        ]
        Resource = "*"
      },
      {
        # SSO and identity store read — mgmt-only. Diagnosis-only;
        # principal-set / permission-set inspection during recovery.
        # No SSO write power (operator's SSO assignments are managed by
        # `management/bootstrap/sso-assignments.tf` — break-glass does
        # not edit those).
        Sid    = "SsoRead"
        Effect = "Allow"
        Action = [
          "sso:Describe*",
          "sso:List*",
          "sso:Get*",
          "identitystore:Describe*",
          "identitystore:List*",
          "identitystore:Get*",
        ]
        Resource = "*"
      },
      {
        # KMS read + Decrypt scoped to local-account keys only. Required
        # for reading SSM PS SecureString values during diagnosis. No
        # Encrypt / GenerateDataKey here — break-glass is read-recovery,
        # not new-encryption.
        Sid    = "KmsReadAndDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Describe*",
          "kms:List*",
          "kms:Get*",
          "kms:Decrypt",
        ]
        Resource = "arn:aws:kms:*:${local.account_id}:key/*"
      },
      {
        # SSM PS read on `/aegis/*` paths only. SaaS credentials and
        # other ADR-028 secrets-persistent values live under this prefix;
        # diagnosis often needs to confirm a token is present and decrypts
        # cleanly. Read-only; no Put / Delete.
        Sid    = "SsmReadProject"
        Effect = "Allow"
        Action = [
          "ssm:Get*",
          "ssm:Describe*",
          "ssm:List*",
        ]
        Resource = "arn:aws:ssm:*:${local.account_id}:parameter/aegis/*"
      },
      {
        # Identity + audit visibility. `sts:GetCallerIdentity` to confirm
        # the assume worked; `tag:Get*` for cross-resource tag enumeration;
        # the two `iam:Generate*` actions to produce credential / access
        # reports during diagnosis. All read-only and AWS-API-shape
        # Resource:* — these actions do not accept resource-level ARNs.
        Sid    = "StsAndTagRead"
        Effect = "Allow"
        Action = [
          "sts:GetCallerIdentity",
          "tag:Get*",
          "iam:GenerateCredentialReport",
          "iam:GenerateServiceLastAccessedDetails",
        ]
        Resource = "*"
      },
    ]
  })
}
