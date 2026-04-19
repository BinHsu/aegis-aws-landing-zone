# -----------------------------------------------------------------------------
# Service Control Policies — Organization-wide Guardrails
# -----------------------------------------------------------------------------
# These SCPs supplement Control Tower's mandatory guardrails with additional
# restrictions aligned to ISO 27001:2022 Annex A (ADR-005).
#
# Control Tower already provides:
#   - Region deny (ADR-002: only eu-central-1 + eu-west-1)
#   - CloudTrail protection (disallow changes/deletion)
#   - AWS Config protection (disallow changes/deletion)
#   - Control Tower-managed IAM role protection
#
# SCPs do NOT apply to the management account — only member accounts.
# Management account root user is protected by MFA + cold storage (Runbook Part 3).
# -----------------------------------------------------------------------------

data "aws_organizations_organization" "current" {}

locals {
  root_id = data.aws_organizations_organization.current.roots[0].id
}

# -----------------------------------------------------------------------------
# SCP 1: Deny Root User Actions in Member Accounts
# ISO 27001:2022 Annex A.8.2 — Privileged access management
# -----------------------------------------------------------------------------
# Blocks all actions by root user in member accounts. Root user access in
# member accounts serves no legitimate operational purpose — all human access
# goes through SSO, all service access goes through IAM roles.
#
# Exceptions: none. If root access is needed for a member account (e.g.,
# changing account-level settings that only root can change), temporarily
# detach this SCP, perform the action, and re-attach.
# -----------------------------------------------------------------------------

resource "aws_organizations_policy" "deny_root_user" {
  name        = "deny-root-user-actions"
  description = "Deny all actions by root user in member accounts. ISO 27001 A.8.2."
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyRootUserActions"
        Effect   = "Deny"
        Action   = "*"
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:PrincipalArn" = "arn:aws:iam::*:root"
          }
        }
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "deny_root_user" {
  policy_id = aws_organizations_policy.deny_root_user.id
  target_id = local.root_id
}

# -----------------------------------------------------------------------------
# SCP 2: Deny IAM User Creation
# ISO 27001:2022 Annex A.8.2 — Privileged access management
# -----------------------------------------------------------------------------
# Enforces the "no IAM users" principle (ADR-001, CLAUDE.md). All human access
# goes through IAM Identity Center (SSO). All programmatic access uses IAM
# roles (OIDC for GitHub, IRSA for K8s workloads).
#
# This SCP blocks IAM user and access key creation across all member accounts.
# If a legitimate exception arises (e.g., a third-party service that only
# supports IAM users), create a targeted exception via a separate SCP at the
# OU level rather than removing this organization-wide guardrail.
# -----------------------------------------------------------------------------

resource "aws_organizations_policy" "deny_iam_users" {
  name        = "deny-iam-user-creation"
  description = "Deny creation of IAM users and access keys. SSO only. ISO 27001 A.8.2."
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyIAMUserCreation"
        Effect = "Deny"
        Action = [
          "iam:CreateUser",
          "iam:CreateLoginProfile",
          "iam:CreateAccessKey",
          "iam:AttachUserPolicy",
          "iam:PutUserPolicy",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "deny_iam_users" {
  policy_id = aws_organizations_policy.deny_iam_users.id
  target_id = local.root_id
}

# -----------------------------------------------------------------------------
# SCP 3: Deny Leaving the Organization
# ISO 27001:2022 Annex A.5.1 — Policies for information security
# -----------------------------------------------------------------------------
# Prevents member accounts from calling organizations:LeaveOrganization.
# An account that leaves the organization escapes all SCPs, loses CloudTrail
# aggregation, and becomes unmanageable. This is a foundational guardrail.
# -----------------------------------------------------------------------------

resource "aws_organizations_policy" "deny_leave_org" {
  name        = "deny-leave-organization"
  description = "Deny member accounts from leaving the organization. ISO 27001 A.5.1."
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyLeaveOrganization"
        Effect   = "Deny"
        Action   = "organizations:LeaveOrganization"
        Resource = "*"
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "deny_leave_org" {
  policy_id = aws_organizations_policy.deny_leave_org.id
  target_id = local.root_id
}
