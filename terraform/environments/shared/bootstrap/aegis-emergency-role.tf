# -----------------------------------------------------------------------------
# `aegis-emergency-break-glass` — break-glass recovery role (ADR-030 OQ-1)
# -----------------------------------------------------------------------------
# Materializes the `aegis-emergency-*` namespace reserved by ADR-030's SCP
# allow-list (`deny-iam-privilege-escalation`). This is the shared-account
# variant — see `terraform/environments/management/bootstrap/aegis-emergency-
# role.tf` for the full design narrative and the recovery shape that
# motivates the role.
#
# Scope difference from mgmt: no Organizations / SSO / IdentityStore Sids.
# Those API surfaces only carry power in mgmt; in member accounts they
# return empty inventories at best and produce no useful break-glass
# primitive. The shared-account permission policy is therefore the IAM /
# KMS / SSM PS subset.
#
# Trust policy: identical pattern to mgmt — local-account PlatformAdmin
# SSO sessions only, time-bounded to 1 hour.
#
# SCP interaction: `aegis-emergency-break-glass` matches `aegis-emergency-*`
# in ADR-030's SCP allow-list. No SCP change required by this PR.
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
  # checkov:skip=CKV_AWS_287: Read-shape Sids (IamReadAll, KmsReadAndDecrypt's Describe/List/Get verbs, StsAndTagRead) intentionally use Resource:* for inventory access during break-glass diagnosis. Mutation surface is in IamMutationOnProjectRoles, scoped or trust-policy-gated. ADR-030 OQ-1.
  # checkov:skip=CKV_AWS_288: Same as 287 — break-glass requires broad read for diagnosis; mutations are scoped. Read-shape data disclosure is the explicit threat model accepted by ADR-030.
  # checkov:skip=CKV_AWS_289: iam:* is intentionally allowed but scoped to aegis-*/gh-tf-*/github-actions-* prefixes. Permission-management within fixed prefixes is the break-glass contract.
  # checkov:skip=CKV_AWS_290: Resource:* on read-only Sids is required because the corresponding AWS APIs do not support resource-level ARN constraints. Trust policy (PlatformAdmin SSO only) is the gate.
  # checkov:skip=CKV_AWS_355: Resource:* is by design on the read-only Sids and on AWS APIs without resource-level ARN support.
  # checkov:skip=CKV2_AWS_40: iam:* on a fixed ARN-prefix scope is the deliberate break-glass design (ADR-030 OQ-1 graduation).
  name = "emergency-break-glass-scoped"
  role = aws_iam_role.aegis_emergency_break_glass.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Scoped IAM mutation — the primary break-glass primitive.
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
        # IAM read across the account. Diagnosis needs full inventory;
        # mutations are bounded by IamMutationOnProjectRoles above.
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
        # KMS read + Decrypt scoped to local-account keys only. Required
        # for reading SSM PS SecureString values during diagnosis. No
        # Encrypt / GenerateDataKey — break-glass is read-recovery.
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
        # SSM PS read on `/aegis/*` paths only. ADR-028 secrets-persistent
        # values live under this prefix; diagnosis often needs to confirm
        # a token is present and decrypts cleanly. Read-only.
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
        # Identity + audit visibility. Read-only; AWS-API-shape Resource:*.
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
