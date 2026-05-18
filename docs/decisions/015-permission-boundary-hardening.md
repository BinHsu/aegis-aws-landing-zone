# 015. IAM Permission-Boundary Hardening

## Status

Accepted (2026-05-04)

## Context

[ADR-014](014-iam-permission-scope-down.md) scoped the CI roles — `gh-tf-plan` (read-only) and `gh-tf-apply-baseline` (org-mutating), keyed off the OIDC `sub` claim. Combined with the GitHub repository-level hardening, Layer 0 (GitHub repo + environment settings) and Layer 3 (IAM permission scope-down) are both walls against the realistic fork-PR-OIDC attack vector.

ADR-014's threat model bounded the fork-PR-OIDC vector: a token leaked to that path can at most run `terraform plan`, which is read-only metadata disclosure. The remaining surface is **second-order** — what happens if the inner wall is ever breached by some other mechanism: a compromised maintainer credential that lands a malicious PR on `main` and is auto-applied; a settings drift episode that re-enables fork dispatch; a GitHub-side approval-gate bug. In any of those scenarios, the attacker arrives holding `gh-tf-apply-baseline` credentials.

`gh-tf-apply-baseline`, by design, must be permitted to call `iam:CreateRole` / `iam:AttachRolePolicy` / `iam:PutRolePolicy` against `arn:aws:iam::*:role/aegis-*` — the baseline layers create the GitHub OIDC provider, the per-account roles, and other IAM as part of legitimate provisioning. **An attacker holding `gh-tf-apply-baseline` can therefore call `iam:CreateRole` for `aegis-evil`, `iam:AttachRolePolicy` to attach `arn:aws:iam::aws:policy/AdministratorAccess`, then `sts:AssumeRole`** — escalating from scoped CI permissions to full Admin via a path the per-role policy cannot itself prevent. Self-modifying the role policy to close the path is a chicken-and-egg problem: the role would have to deny itself an action it currently uses to apply legitimate IAM resources.

The resolution is to push the wall above the role layer — to the SCP layer in the management account, which apply-tier roles cannot self-modify by definition. This ADR groups four hardenings against inner-wall-breach scenarios:

| Item | Layer | Action | Scope |
|---|---|---|---|
| A | SCP | `deny-iam-privilege-escalation` | Org-wide deny on IAM mutating actions, allow-list for legitimate identities |
| B | Resource policy | State bucket + KMS key policy hardening | Tighten `aws:PrincipalOrgID` to an enumerated principal allow-list |
| C | Trust policy | `repository_id` numeric claim binding | Add to OIDC trust policies across the role surface |
| D | Tag conditions | `aws:ResourceTag/Project` on apply-tier policies | Prevent mutation of name-spoofed resources missing the project tag |

Item A is implemented. Items B / C / D are documented here as Accepted decisions with implementation deferred to follow-up PRs. Splitting them avoids a large bundled change against the security boundary; each follow-up gets its own PR, its own CI plan review, and its own rollback unit.

## Decision

### A. SCP `deny-iam-privilege-escalation`

A new `aws_organizations_policy` lands in `terraform/environments/management/scps/main.tf`, attached to the org root (same shape as the existing SCPs). The policy denies the following IAM actions for any principal not in the allow-list:

- Role mutation: `iam:CreateRole`, `iam:UpdateAssumeRolePolicy`, `iam:AttachRolePolicy`, `iam:DetachRolePolicy`, `iam:PutRolePolicy`, `iam:DeleteRolePolicy`
- User mutation: `iam:CreateUser`, `iam:AttachUserPolicy`, `iam:PutUserPolicy`
- Policy mutation: `iam:CreatePolicyVersion`, `iam:SetDefaultPolicyVersion`
- Instance profile mutation: `iam:CreateInstanceProfile`, `iam:AddRoleToInstanceProfile`
- `iam:PassRole`

The allow-list (matched via `ArnNotLike` on `aws:PrincipalArn`):

| Pattern | Identity | Reason |
|---|---|---|
| `arn:aws:iam::*:role/AWSControlTowerExecution` | Control Tower | Account provisioning |
| `arn:aws:iam::*:role/aws-controltower-*` | Control Tower | Landing zone management |
| `arn:aws:iam::*:role/stacksets-exec-*` | StackSets | StackSet-driven IAM |
| `arn:aws:iam::*:role/gh-tf-*` | CI roles (ADR-014) | `gh-tf-apply-baseline` legitimately creates IAM |
| `arn:aws:iam::*:role/aegis-emergency-*` | Break-glass pattern | Reserved namespace per `docs/principles/break-glass-apply.md` |
| `arn:aws:iam::*:role/*-karpenter-controller` | Karpenter controller (IRSA) | Runtime instance-profile management (see below) |

`iam:CreateServiceLinkedRole` is intentionally **not** in the deny list. AWS auto-creates SLRs for many services (`spot.amazonaws.com`, `eks.amazonaws.com`, etc.) and apply roles legitimately trigger this action when first provisioning. SLR trust policies are AWS-controlled, so the privilege-escalation primitive is bounded.

**Karpenter controller carve-out.** This SCP is org-wide — it applies to every member account, including the workload accounts. A workload account's Karpenter controller (running as an IRSA-bound service account) calls `iam:PassRole`, `iam:CreateInstanceProfile`, `iam:AddRoleToInstanceProfile`, and `iam:RemoveRoleFromInstanceProfile` at runtime to manage the EC2 instance-profile lifecycle for Karpenter-provisioned nodes. Without an exception, this org-wide SCP would break that controller. The exception is bounded — the controller's own inline policy already scopes these actions by cluster tag, region, and instance-profile ARN — so the SCP carve-out only re-permits actions that the controller's own boundary already constrains. The pattern uses a wildcard `*-karpenter-controller` so it covers a controller role regardless of the cluster name prefix.

**AWS service principals are not subject to SCPs.** SCPs apply to IAM principals (users + roles) only. AWS service principals bypass SCP evaluation entirely. This is documented AWS behavior — see [What SCPs don't affect](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html).

The SCP attaches to `local.root_id` and applies to all member accounts — same shape as the existing SCPs. `terraform-apply-baseline.yml` auto-applies it on merge to `main`.

### B. State bucket + KMS key policy hardening (DEFERRED)

`aws_kms_key.terraform_state` (in `shared/bootstrap/kms-state.tf`) currently uses `aws:PrincipalOrgID` to allow any org principal `kms:Decrypt` / `kms:Encrypt`. The state bucket has a similar `aws:PrincipalOrgID` condition. Both are correct for the ADR-014 baseline — any account in the org with a valid SSO assumption can read its own state file.

Tightening would replace the broad org-wide condition with an enumerated principal allow-list: `gh-tf-*`, `AWSControlTowerExecution`, `aegis-emergency-*`. The marginal value is bounded — cross-account access already requires a valid org principal, which requires SSO + valid role assumption. The escalation path closed by item A is the higher-value primitive.

Deferred to a follow-up PR. Implementation: edit the KMS key policy in `terraform/environments/shared/bootstrap/kms-state.tf` and the bucket policy in `terraform/environments/shared/bootstrap/state-bucket.tf` to add an explicit `Deny` for principals outside the allow-list.

### C. `repository_id` numeric claim binding (DEFERRED)

Extend the OIDC trust policies with the `repository_id` numeric claim. Unlike `repository` (string, mutable on rename), `repository_id` is GitHub's immutable numeric identifier. A trust policy bound to `repository_id` survives a repo rename and rejects a forked-and-renamed-back attack.

Files in scope: `oidc-github*.tf` in `terraform/environments/management/bootstrap/`, `terraform/environments/shared/bootstrap/`, and `terraform/environments/staging/bootstrap/`.

Deferred to a follow-up PR. The defense it provides is against the `repo-renamed` edge case, not the primary fork-PR-OIDC vector ADR-014 closed.

### D. `aws:ResourceTag/Project` conditions on the apply-tier policy (DEFERRED)

The `gh-tf-apply-baseline` policy currently scopes by ARN prefix only — e.g., `arn:aws:iam::*:role/aegis-*`. An attacker who can `iam:CreateRole aegis-evil` (now blocked by item A but historically possible) could create a name-spoofed resource and have the apply-tier role legitimately mutate it.

Adding `Condition: { StringEquals: { "aws:ResourceTag/Project": "landing-zone-lab" } }` on Create / Update / Delete actions would force every mutation to target a resource that carries the project tag. Combined with item A, this makes name-spoofing useless.

Caveat: not all AWS services support `aws:ResourceTag` as a condition key on Create. Per-service support has to be checked at policy-write time.

Deferred to a follow-up PR. The work is not large in line count but requires a per-service audit of condition-key support; bundling it with item A would inflate the review surface.

## Alternatives Considered

### A1. Do nothing — accept ADR-014 as the wall

Rejected. The privilege-escalation path described in Context is real and well-known in the AWS security literature — see "AWS IAM Privilege Escalation Methods" (Rhino Security Labs). ADR-014 explicitly noted Layer 3 alone bounds blast radius for fork-PR-OIDC but does not close every inner-wall-breach scenario. Accepting ADR-014 as the wall would leave the apply-tier-to-Admin escalation path open. The marginal cost of the SCP is one resource block; the value is closing a documented escalation primitive.

### A2. Permission boundary policies on the apply role instead of an SCP

Rejected. Permission boundaries are per-role; a compromised role could call `iam:DeleteRolePermissionsBoundary` on itself if that action were permitted, or the boundary policy itself could be modified by `iam:CreatePolicyVersion` / `iam:SetDefaultPolicyVersion` if those actions were permitted. The wall has to live above the role's own scope. SCPs are managed in the management account; apply-tier roles in member accounts cannot reach them. SCP is the structurally correct layer.

### A3. Bundle items A / B / C / D into a single PR

Rejected. The combined diff would touch SCPs (1 file), KMS + bucket policies (2 files), OIDC trust policies (several files), and the apply-tier role policy (3 files). Reviewing that surface in one PR is the kind of "too big to review carefully" change `docs/principles/change-review-discipline.md` step 5 ("2 AM readability") explicitly warns against. Per-item PRs preserve the audit trail and the per-item rollback unit.

## Consequences

### Makes easier

- The apply-tier-to-Admin privilege escalation path is closed at the org level. A compromised `gh-tf-apply-baseline` can no longer self-promote to Admin via `iam:CreateRole` + `iam:AttachRolePolicy`.
- The four-item progression is a documented unit. A reviewer or forker reading ADR-014 → ADR-015 sees the threat model and can audit each layer independently.
- The break-glass pattern `aegis-emergency-*` gains a documented namespace via the SCP allow-list. Future incident-only roles do not require an SCP amendment to land.
- CloudTrail `DeniedAccess` on `iam:CreateRole` / `iam:AttachRolePolicy` from an unexpected principal is now a high-signal alert primitive — the only legitimate callers are enumerated. This is the event class ADR-016 builds detective alerting on.

### Makes harder

- One additional SCP to audit when reviewing org-level changes.
- A new `aegis-*`-prefix IAM-mutating identity (e.g., a future controller that needs `iam:PassRole`) must either match an existing allow-list pattern or trigger an SCP amendment. The change-review checklist gains a corresponding "does this layer add a new IAM-mutating identity?" line in a future amendment to `docs/principles/change-review-discipline.md`.
- If item D ships, every new resource type added to the apply-tier policy must be audited for `aws:ResourceTag` condition-key support.

### Risks

- An IAM-mutating runtime caller missing from the allow-list breaks silently — the action fails with `AccessDenied`, the workflow fails, the operator must diagnose. The single non-CI runtime caller of the deny-listed actions is a workload account's Karpenter controller, covered by the `*-karpenter-controller` allow-list pattern; future additions (e.g., a service-mesh control plane that creates IRSA at runtime) require an explicit SCP amendment.
- The SCP applies to all member accounts. A misconfigured allow-list pattern (typo in `gh-tf-*`) can lock out the apply tier from creating any IAM. Mitigation: the SCP's pattern is matched against ARNs whose shape is verified at PR review time.
- `iam:PassRole` denial across the org has historically tripped non-obvious code paths. The check is part of `docs/principles/change-review-discipline.md` step 1 ("Blast radius") — IAM-mutating callers are a known surface.

## Related

- [ADR-014](014-iam-permission-scope-down.md) — the CI role scope-down; this ADR is the inner-wall complement that bounds `gh-tf-apply-baseline` if it is ever compromised.
- [ADR-002](002-region-and-availability-zone-strategy.md) — sibling SCP guardrail; this ADR composes with it (a compromised apply-tier token cannot operate outside `eu-central-1` / `eu-west-1` AND cannot create new IAM roles to escape into).
- [ADR-005](005-compliance-framework-iso-27001.md) — the ISO 27001:2022 Annex A.8.2 control reference cited by every SCP in this file.
- [ADR-016](016-detective-controls.md) — the detective layer that alerts on the denied IAM-mutation events this SCP produces.
- [`docs/principles/break-glass-apply.md`](../principles/break-glass-apply.md) — the break-glass discipline that motivates the `aegis-emergency-*` allow-list namespace.
- [`docs/principles/change-review-discipline.md`](../principles/change-review-discipline.md) — the 5-step pre-merge checklist that gains an implicit "new IAM-mutating identity?" line.

## Appendix A — Implementation Pointer

Item A ships as a single new resource pair in `terraform/environments/management/scps/main.tf`:

- `aws_organizations_policy.deny_iam_privilege_escalation` — the SCP definition, ~50 lines including header banner.
- `aws_organizations_policy_attachment.deny_iam_privilege_escalation` — attached to `local.root_id` (the org root), matching the existing SCPs' attachment shape.

The file's existing structure (header banner + `data "aws_organizations_organization" "current"` + `local.root_id` + the existing SCP blocks) is preserved; the new block is appended after `deny_leave_org`.
