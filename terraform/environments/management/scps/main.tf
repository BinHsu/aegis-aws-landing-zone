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

# -----------------------------------------------------------------------------
# SCP 4: Deny IAM Privilege Escalation
# ISO 27001:2022 Annex A.8.2 — Privileged access management
# -----------------------------------------------------------------------------
# Closes the "inner-wall-breach" privilege-escalation path documented in
# ADR-030. After ADR-029, the apply-tier roles (`gh-tf-apply-baseline`,
# `gh-tf-apply-workload`) carry purpose-scoped policies — but those policies
# still permit `iam:CreateRole` / `iam:AttachRolePolicy` against
# `arn:aws:iam::*:role/aegis-*` because the apply layers legitimately create
# IAM roles (cluster IAM, IRSA, OIDC providers, etc.). Without this SCP, an
# attacker who hijacked an apply-tier role could create a new role, attach
# `AdministratorAccess` to it, and assume it — escalating from scoped CI
# permissions to full Admin via a path the per-role policy cannot itself
# prevent.
#
# This SCP applies the wall at the org level: the listed mutating IAM
# actions are denied for every principal in every member account, EXCEPT
# the explicit allow-list of legitimate identities. A compromised apply-tier
# role cannot self-modify the SCP, by definition — SCPs are managed in the
# management account, which is outside the apply-tier roles' scope.
#
# Allow-list rationale:
#   - AWSControlTowerExecution / aws-controltower-* / stacksets-exec-* —
#     Control Tower / StackSets create and modify IAM during account
#     provisioning; required for the platform to function.
#   - github-actions-terraform — legacy Admin role retained during the
#     ADR-029 rollout window; will be removed when the cleanup PR drops it.
#   - gh-tf-* — the four purpose-scoped CI roles that supersede the legacy
#     role per ADR-029. Apply-tier members of this family legitimately create
#     IAM roles for new infrastructure.
#   - aegis-emergency-* — break-glass pattern aligned with
#     `docs/principles/break-glass-apply.md`. Aspirational at present (no role
#     of this name exists yet); the SCP allow-list reserves the namespace so
#     a future incident-only role does not require an SCP amendment to land.
#   - *-karpenter-controller — Karpenter IRSA role calls `iam:PassRole`,
#     `iam:CreateInstanceProfile`, `iam:AddRoleToInstanceProfile`, and
#     `iam:RemoveRoleFromInstanceProfile` at runtime to manage EC2 instance
#     profiles for nodes. Karpenter's own policy already scopes these by tag
#     and resource ARN; the SCP exception unblocks the legitimate code path
#     without weakening Karpenter's own boundary.
#
# Service-Linked Roles (`iam:CreateServiceLinkedRole`) are intentionally
# NOT in the deny list — AWS auto-creates SLRs for many services
# (`spot.amazonaws.com`, `eks.amazonaws.com`, etc.) and apply roles
# legitimately trigger this action when first provisioning a service.
# The risk is bounded because SLR trust policies are AWS-controlled.
#
# AWS service principals (e.g., `eks.amazonaws.com` assuming roles internally
# during cluster operations) are NOT subject to SCPs — SCPs apply to IAM
# principals (users + roles) only. This is documented AWS behavior; see
# https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
# under "What SCPs don't affect."
# -----------------------------------------------------------------------------

resource "aws_organizations_policy" "deny_iam_privilege_escalation" {
  name        = "deny-iam-privilege-escalation"
  description = "Deny IAM principal/policy mutation by anything other than AWS-managed and break-glass identities. ISO 27001 A.8.2."
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyIamPrivilegeEscalation"
        Effect = "Deny"
        Action = [
          "iam:CreateRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:CreateUser",
          "iam:AttachUserPolicy",
          "iam:PutUserPolicy",
          "iam:CreatePolicyVersion",
          "iam:SetDefaultPolicyVersion",
          "iam:CreateInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:PassRole",
        ]
        Resource = "*"
        Condition = {
          ArnNotLike = {
            "aws:PrincipalArn" = [
              "arn:aws:iam::*:role/AWSControlTowerExecution",
              "arn:aws:iam::*:role/aws-controltower-*",
              "arn:aws:iam::*:role/stacksets-exec-*",
              "arn:aws:iam::*:role/github-actions-terraform",
              "arn:aws:iam::*:role/gh-tf-*",
              "arn:aws:iam::*:role/aegis-emergency-*",
              "arn:aws:iam::*:role/*-karpenter-controller",
            ]
          }
        }
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "deny_iam_privilege_escalation" {
  policy_id = aws_organizations_policy.deny_iam_privilege_escalation.id
  target_id = local.root_id
}
