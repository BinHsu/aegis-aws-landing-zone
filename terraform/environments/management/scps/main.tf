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

  # ADR-020 boundary identity. The SCP is one document attached at the org root
  # and evaluated in every member account, so the boundary ARN it references is
  # account-wildcarded (`::*:`) — each account holds its own copy of the
  # byte-identical `aegis-landing-zone-aws-ci-boundary` policy (ADR-020 OQ-1). A
  # permissions boundary must live in the same account as the role it caps, so
  # the wildcard cannot match a cross-account attacker-controlled policy; it
  # only ever resolves to the in-account Aegis boundary.
  ci_boundary_name        = "aegis-landing-zone-aws-ci-boundary"
  ci_boundary_arn_pattern = "arn:aws:iam::*:policy/${local.ci_boundary_name}"
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
# ADR-015. The apply-tier role (`gh-tf-apply-baseline`) carries a purpose-
# scoped policy — but that policy still permits `iam:CreateRole` /
# `iam:AttachRolePolicy` against `arn:aws:iam::*:role/aegis-*` because the
# apply layers legitimately create IAM roles (OIDC providers, break-glass
# roles, etc.). Without this SCP, an attacker who hijacked the apply-tier
# role could create a new role, attach `AdministratorAccess` to it, and
# assume it — escalating from scoped CI permissions to full Admin via a path
# the per-role policy cannot itself prevent.
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
#   - gh-tf-* — the purpose-scoped CI roles per ADR-014
#     (gh-tf-plan / gh-tf-apply-baseline). The apply-tier member of this
#     family legitimately creates IAM roles for new infrastructure.
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
#   (Removed 2026-06-19, ADR-21 §A) aegis-platform-aws-ack-iam-* was the
#     in-cluster Crossplane/ACK IAM controller's carve-out. That controller is
#     retired (aegis-platform-aws #117 deletes crossplane.tf + irsa-ack-iam.tf +
#     the aegis-xrds chart). Engine IAM is now a Terraform-owned role created by
#     the gh-tf-* apply role (already allow-listed above) and delivered via EKS
#     Pod Identity; no in-cluster principal calls iam:CreateRole anymore, so the
#     carve-out is removed to re-tighten the wall.
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
#
# ADR-020 extension (S1 + S2) — closes the residual the name exemption above
# leaves open. The base statement watches the CALLER'S name; it exempts
# `gh-tf-*` because the apply tier legitimately runs `iam:CreateRole`. But a
# name exemption cannot constrain what the exempted identity CREATES, so a
# hijacked `gh-tf-*` role could still mint `aegis-evil`, attach
# `AdministratorAccess`, and assume it (#313). ADR-020 caps that by forcing the
# `aegis-landing-zone-aws-ci-boundary` permissions boundary onto everything the
# CI tier creates, and protecting the boundary document from the CI tier:
#
#   S1 (DenyUnboundedRoleCreateByCi + DenyBoundaryStripByCi) — deny-SCOPED-TO
#      `gh-tf-*` (ArnLike, not the base statement's ArnNotLike allow-list).
#      Every OTHER identity is out of S1's scope BY CONSTRUCTION, not by
#      exemption — so break-glass seeding of `gh-tf-*` roles (Runbook 002) and
#      any future IAM-mutating identity never trip S1. This is the shape #319
#      wants for the base statement; S1 does not add to the name-exemption debt
#      #319 tracks, and deliberately does not "fix" #319 here.
#   S2 (ProtectBoundaryPolicy) — deny mutation of the boundary DOCUMENT by all
#      member principals except `aegis-emergency-*`. The single break-glass
#      carve-out is the in-account repair path (ADR-020 D3): IAM policies are
#      account-local, so without it a corrupted boundary would be unrepairable
#      short of detaching this whole SCP at the org root. It is one narrowly
#      scoped exemption (one resource, one principal family already trusted as
#      break-glass), not a widening of the base allow-list.
#
# Boundary-ARN matching uses ArnLike/ArnNotLike with an account-wildcarded ARN
# (`local.ci_boundary_arn_pattern`) because this one SCP document is evaluated
# in every account and each holds its own copy of the boundary. ADR-020 D2
# phrases this as `StringNotEquals the boundary ARN`; StringNotEquals cannot
# wildcard the account segment, so ArnNotLike is the faithful cross-account
# implementation of the same intent (see PR body).
#
# Rollout ordering (ADR-020 D4): S1/S2 land ONLY after PR-1's boundary policy is
# applied in every member account. Otherwise CI's first `CreateRole` here would
# reference a nonexistent boundary ARN and fail. PR-1 (#325) is merged and
# applied in all accounts before this statement lands.
# -----------------------------------------------------------------------------

resource "aws_organizations_policy" "deny_iam_privilege_escalation" {
  name        = "deny-iam-privilege-escalation"
  description = "Deny IAM principal/policy mutation by non-AWS-managed/break-glass identities; force+protect the CI permissions boundary (ADR-015 Item A + ADR-020 S1/S2). ISO 27001 A.8.2."
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
              "arn:aws:iam::*:role/gh-tf-*",
              "arn:aws:iam::*:role/aegis-emergency-*",
              "arn:aws:iam::*:role/*-karpenter-controller",
            ]
          }
        }
      },
      # --- ADR-020 S1 -------------------------------------------------------
      # Force the boundary onto everything the CI tier creates. Deny-scoped-TO
      # `gh-tf-*` (ArnLike). `iam:CreateRole` / `iam:PutRolePermissionsBoundary`
      # are denied unless `iam:PermissionsBoundary` is the Aegis boundary. When
      # a `gh-tf-*` caller creates a role WITHOUT any boundary, the
      # `iam:PermissionsBoundary` key is absent and the negated ArnNotLike
      # matches → the create is denied. Converging a boundary-less break-glass-
      # seeded role IS `PutRolePermissionsBoundary` to the correct ARN, which
      # this statement allows (ArnNotLike false) — so cold-start seeding
      # (Runbook 002) is untouched. `iam:PermissionsBoundary` exists only on
      # Create*/Put*PermissionsBoundary, so those are the only actions this
      # statement can and needs to condition (ADR-020 D2 technical note).
      {
        Sid    = "DenyUnboundedRoleCreateByCi"
        Effect = "Deny"
        Action = [
          "iam:CreateRole",
          "iam:PutRolePermissionsBoundary",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "aws:PrincipalArn" = "arn:aws:iam::*:role/gh-tf-*"
          }
          ArnNotLike = {
            "iam:PermissionsBoundary" = local.ci_boundary_arn_pattern
          }
        }
      },
      # A bounded CI identity can never strip a boundary (its own or another's).
      # Unconditional for `gh-tf-*` callers — `iam:DeleteRolePermissionsBoundary`
      # carries no `iam:PermissionsBoundary` key to condition on. Split from the
      # statement above so the "unconditional" intent (ADR-020 D2) is explicit
      # rather than resting on absent-key semantics.
      {
        Sid    = "DenyBoundaryStripByCi"
        Effect = "Deny"
        Action = [
          "iam:DeleteRolePermissionsBoundary",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "aws:PrincipalArn" = "arn:aws:iam::*:role/gh-tf-*"
          }
        }
      },
      # --- ADR-020 S2 -------------------------------------------------------
      # Protect the boundary DOCUMENT from rewrite/removal. Denied for every
      # member principal EXCEPT `aegis-emergency-*` (ArnNotLike) — the break-
      # glass in-account repair path (ADR-020 D3). No `gh-tf-*` exemption by
      # design: a CI role that can rewrite its own boundary defeats the whole
      # control, so post-PR-2 boundary evolution is a break-glass ceremony
      # (ADR-020 Consequences → Makes harder). `iam:CreatePolicy` is NOT denied,
      # so break-glass cold-start creation of the boundary still works.
      {
        Sid    = "ProtectBoundaryPolicy"
        Effect = "Deny"
        Action = [
          "iam:CreatePolicyVersion",
          "iam:SetDefaultPolicyVersion",
          "iam:DeletePolicy",
          "iam:DeletePolicyVersion",
        ]
        Resource = local.ci_boundary_arn_pattern
        Condition = {
          ArnNotLike = {
            "aws:PrincipalArn" = "arn:aws:iam::*:role/aegis-emergency-*"
          }
        }
      },
    ]
  })
}

resource "aws_organizations_policy_attachment" "deny_iam_privilege_escalation" {
  policy_id = aws_organizations_policy.deny_iam_privilege_escalation.id
  target_id = local.root_id
}
