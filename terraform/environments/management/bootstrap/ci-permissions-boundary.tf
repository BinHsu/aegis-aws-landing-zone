# -----------------------------------------------------------------------------
# `aegis-landing-zone-aws-ci-boundary` — SCP-enforced CI permissions boundary
# (ADR-020 D1). PR-1 of the ADR-020 rollout: the boundary policy plus its
# attachment to every CI (`gh-tf-*`) role. The SCP statements S1/S2 that make
# the boundary mandatory org-wide are PR-2 and land only after this policy is
# applied in every account (ADR-020 D4).
# -----------------------------------------------------------------------------
# WHAT THIS IS: a permissions BOUNDARY — a ceiling, not a grant. Attaching it to
# a role cannot expand that role's permissions; it can only intersect them. A
# bounded role's effective permissions are (its identity policy) ∩ (this
# boundary). The wide Allow below is the outer cap; per-role least-privilege
# scoping stays in each role's own policy (ADR-014). The load-bearing security
# control is the explicit Deny floor, which no Allow can override.
#
# SINGLE ORG-UNIFORM DOCUMENT (ADR-020 OQ-1, decided by Bin 2026-07-07): this
# file is byte-identical across all seven `*/bootstrap` layers. The only
# per-account input is `local.account_id`, used to build the boundary's own ARN
# in the deny-floor conditions. Drift between the seven copies is a bug — audit
# with `diff`/`md5`.
#
# NOT ATTACHED TO `aegis-emergency-break-glass` — see the attachment note in
# each `oidc-github-*-role.tf` / this file's tail. Break-glass is the designated
# in-account repair path for a corrupted boundary (ADR-020 D3); a bounded
# break-glass would be blocked by this document's own `DenyMutateBoundaryPolicy`
# clause and could not repair it. Break-glass is also outside SCP S1's scope by
# construction (S1 is deny-scoped-to `gh-tf-*` callers). See PR body — flagged
# as a decision point against ADR-020 D1's literal "every managed role" wording.
# -----------------------------------------------------------------------------

locals {
  ci_boundary_name = "aegis-landing-zone-aws-ci-boundary"
  ci_boundary_arn  = "arn:aws:iam::${local.account_id}:policy/${local.ci_boundary_name}"
}

data "aws_iam_policy_document" "ci_boundary" {
  # This document is a permissions BOUNDARY (a ceiling), never attached as a
  # grant. Attaching it cannot expand any identity's permissions — it only
  # intersects. The wide Allow is the outer cap required by ADR-020 D1/OQ-1;
  # the load-bearing control is the explicit Deny floor below, which no Allow
  # can override. Per-role least privilege lives in the ADR-014 role policies.
  # Checkov evaluates the rendered policy statically and cannot tell a boundary
  # ceiling from a grant, so the wildcard-policy checks are skipped with that
  # rationale (the same posture ADR-014 role policies already carry):
  # checkov:skip=CKV_AWS_107: Boundary ceiling, not a grant. Credential-exposure breadth is capped here, not granted; each role's own ADR-014 policy is the actual scope.
  # checkov:skip=CKV_AWS_108: Boundary ceiling — data-exfiltration scoping is enforced by each role's ADR-014 policy, of which this boundary is only the outer cap.
  # checkov:skip=CKV_AWS_109: `iam:*` in the Allow is the ceiling; permissions-management escalation is denied by DenyMutateBoundaryPolicy / DenyStripAnyBoundary / DenyPutNonAegisBoundary, not by narrowing the Allow.
  # checkov:skip=CKV_AWS_110: Privilege escalation is closed by this document's own Deny floor (DenyCreateWithoutAegisBoundary forces the boundary onto every created identity), not by removing wildcards from the ceiling.
  # checkov:skip=CKV_AWS_111: Write access is constrained by the Deny floor plus each role's resource-scoped ADR-014 policy; a boundary cannot enumerate per-ARN writes without duplicating every role policy.
  # checkov:skip=CKV_AWS_356: Resource:* is required for a namespace-level permissions boundary. The restrictable-action constraint is enforced at the role-policy layer (ADR-014); this document is the ceiling above it.
  # checkov:skip=CKV2_AWS_40: `iam:*` is intentional in a permissions boundary — it is the ceiling that lets bounded ADR-014 roles run their scoped IAM operations. Full-IAM escalation is closed by the Deny floor.

  # --- Allow floor: the outer cap ------------------------------------------
  # Union of service namespaces the CI-managed roles legitimately use
  # (ADR-020 Appendix A). `ecr` + `sts` cover the platform CI's
  # `gh-tf-apply-deployment` shared-registry surface verified in the ADR-020
  # pre-PR-1 cross-repo step. Namespace-level Allow is intentional: the
  # boundary is a ceiling, and enumerating actions here would duplicate the
  # ADR-014 per-role policies at a second layer and break on every legitimate
  # surface addition.
  statement {
    sid    = "AllowServiceNamespaceCeiling"
    effect = "Allow"
    actions = [
      "iam:*",
      "s3:*",
      "kms:*",
      "ec2:*",
      "ram:*",
      "tag:*",
      "budgets:*",
      "events:*",
      "sns:*",
      "organizations:*",
      "sso:*",
      "identitystore:*",
      "guardduty:*",
      "securityhub:*",
      "ssm:*",
      "sts:*",
      "ecr:*",
    ]
    resources = ["*"]
  }

  # --- Deny floor: the non-negotiable escalation guard ---------------------
  # An explicit Deny overrides every Allow (in this boundary and in any
  # identity policy). These clauses are what actually close #313.

  # A bounded identity can never strip a boundary — including its own.
  statement {
    sid    = "DenyStripAnyBoundary"
    effect = "Deny"
    actions = [
      "iam:DeleteRolePermissionsBoundary",
      "iam:DeleteUserPermissionsBoundary",
    ]
    resources = ["*"]
  }

  # A bounded identity cannot swap in a permissive boundary: any
  # Put*PermissionsBoundary must set THIS boundary's ARN.
  statement {
    sid    = "DenyPutNonAegisBoundary"
    effect = "Deny"
    actions = [
      "iam:PutRolePermissionsBoundary",
      "iam:PutUserPermissionsBoundary",
    ]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.ci_boundary_arn]
    }
  }

  # Self-propagating: any role/user a bounded identity creates must carry THIS
  # boundary. A create without it (condition key absent → StringNotEquals is
  # true) is denied. This is what caps the `CreateRole → AttachRolePolicy(
  # AdministratorAccess) → AssumeRole` primitive regardless of the created
  # role's name or attachments (ADR-020 §"What the boundary adds").
  statement {
    sid    = "DenyCreateWithoutAegisBoundary"
    effect = "Deny"
    actions = [
      "iam:CreateRole",
      "iam:CreateUser",
    ]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.ci_boundary_arn]
    }
  }

  # A bounded identity cannot rewrite the boundary document itself. Mirrors
  # SCP S2 (ADR-020 D3) at the boundary-document layer; boundary evolution is
  # a break-glass ceremony by design. Break-glass is not bounded (see header),
  # so this clause does not block the D3 repair path.
  statement {
    sid    = "DenyMutateBoundaryPolicy"
    effect = "Deny"
    actions = [
      "iam:CreatePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
    ]
    resources = ["arn:aws:iam::*:policy/${local.ci_boundary_name}"]
  }
}

resource "aws_iam_policy" "ci_boundary" {
  # Checkov evaluates the policy JSON on the data source above (where the skips
  # live); this resource only wires that rendered document to the managed
  # policy. It is a permissions boundary — a ceiling, never attached as a grant.
  name        = local.ci_boundary_name
  description = "ADR-020 SCP-enforced CI permissions boundary. Outer cap on every gh-tf-* CI identity; the Deny floor blocks boundary self-removal, unbounded role/user creation, and mutation of the boundary document. This is a ceiling, not a grant."
  policy      = data.aws_iam_policy_document.ci_boundary.json
  tags        = local.tags
}
