# 030. Tier 2B Permission Boundary Hardening

## Status

Accepted (2026-05-04). Item A implemented in this PR; items B/C/D Accepted with implementation deferred to follow-up PRs.

## Context

[ADR-029](029-iam-permission-scope-down.md) closed Tier 1 — the three over-privileged `github-actions-terraform` roles were replaced by four purpose-scoped roles per account, keyed off the OIDC `sub` claim. Combined with [aegis-core#112](https://github.com/BinHsu/aegis-core/issues/112) and [ldz#170](https://github.com/BinHsu/aegis-aws-landing-zone/issues/170), Layer 0 (GitHub repo + environment settings) and Layer 3 (IAM permission scope-down) are now both walls against the realistic fork-PR-OIDC attack vector.

ADR-029's threat model bounded the fork-PR-OIDC vector: a token leaked to that path can at most run `terraform plan`, which is read-only metadata disclosure. The remaining surface is **second-order** — what happens if the inner wall is ever breached by some other mechanism: a compromised maintainer credential that lands a malicious PR on `main` and is auto-applied; a future settings drift episode (the kind ldz#170's `deployment_branch_policy: null` was caught as) that re-enables fork dispatch; a GitHub-side approval-gate bug. In any of those scenarios, the attacker arrives holding `gh-tf-apply-baseline` or `gh-tf-apply-workload` credentials.

The apply-tier roles, by design, must be permitted to call `iam:CreateRole` / `iam:AttachRolePolicy` / `iam:PutRolePolicy` against `arn:aws:iam::*:role/aegis-*` — the apply layers create cluster IAM, IRSA, OIDC providers, etc. as part of legitimate provisioning. **An attacker holding an apply-tier role can therefore call `iam:CreateRole` for `aegis-evil`, `iam:AttachRolePolicy` to attach `arn:aws:iam::aws:policy/AdministratorAccess`, then `sts:AssumeRole`** — escalating from scoped CI permissions to full Admin via a path the per-role policy cannot itself prevent. Self-modifying the role policy to close the path is a chicken-and-egg problem: the role would have to deny itself an action it currently uses to apply legitimate IAM resources.

The resolution is to push the wall above the role layer — to the SCP layer in the management account, which apply-tier roles cannot self-modify by definition. Tier 2B groups four hardenings against inner-wall-breach scenarios:

| Item | Layer | Action | Scope |
|---|---|---|---|
| A | Layer 4 — SCP | `deny-iam-privilege-escalation` | Org-wide deny on IAM mutating actions, allow-list for legitimate identities |
| B | Layer 3.5 — Resource policy | State bucket + KMS key policy hardening | Tighten `aws:PrincipalOrgID` to enumerated principal allow-list |
| C | Layer 2.5 — Trust policy | `repository_id` numeric claim binding | Add to OIDC trust policies across both repos' role surfaces |
| D | Layer 3 — Tag conditions | `aws:ResourceTag/Project` on apply-tier policies | Prevent mutation of name-spoofed resources missing the project tag |

Item A is implemented in this PR. Items B / C / D are documented here as Accepted decisions with implementation deferred to follow-up PRs in subsequent sessions. Splitting them avoids a large bundled change against the security boundary; each follow-up gets its own PR, its own CI plan review, and its own rollback unit.

## Decision

### A. Layer 4 — SCP `deny-iam-privilege-escalation` (SHIPPED)

A new `aws_organizations_policy` lands in `terraform/environments/management/scps/main.tf`, attached to the org root (same shape as the three existing SCPs). The policy denies the following IAM actions for any principal not in the allow-list:

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
| `arn:aws:iam::*:role/github-actions-terraform` | Legacy Admin role | Retained during ADR-029 rollout window; removed in cleanup PR |
| `arn:aws:iam::*:role/gh-tf-*` | ADR-029 four-role family | Apply-tier members legitimately create IAM |
| `arn:aws:iam::*:role/aegis-emergency-*` | Break-glass pattern | Reserved namespace per `docs/principles/break-glass-apply.md` |
| `arn:aws:iam::*:role/*-karpenter-controller` | Karpenter IRSA | Runtime instance-profile management (see below) |

`iam:CreateServiceLinkedRole` is intentionally **not** in the deny list. AWS auto-creates SLRs for many services (`spot.amazonaws.com`, `eks.amazonaws.com`, etc.) and apply roles legitimately trigger this action when first provisioning. SLR trust policies are AWS-controlled, so the privilege-escalation primitive is bounded.

**Karpenter controller (IRSA) carve-out**. The Karpenter controller IRSA role calls `iam:PassRole`, `iam:CreateInstanceProfile`, `iam:AddRoleToInstanceProfile`, and `iam:RemoveRoleFromInstanceProfile` at runtime to manage the EC2 instance profile lifecycle for Karpenter-provisioned nodes. Without an exception, this SCP would break Karpenter. The exception is bounded — Karpenter's own inline policy already scopes these actions by `aws:RequestTag/kubernetes.io/cluster/<name>`, region tag, and `arn:aws:iam::<account>:instance-profile/*` — so the SCP carve-out only re-permits actions that Karpenter's own boundary already constrains. The pattern uses a wildcard `*-karpenter-controller` to cover the K=2 slot pattern (`<cluster>-karpenter-controller` per cluster).

**AWS service principals are not subject to SCPs**. SCPs apply to IAM principals (users + roles) only. AWS service principals (e.g., `eks.amazonaws.com` assuming a service-internal role during cluster operations) bypass SCP evaluation entirely. This is documented AWS behavior — see [What SCPs don't affect](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html). The SCP is therefore safe against the "EKS internally creates IRSA mappings" concern raised during review.

**Rollout sequencing**. The SCP attaches to `local.root_id` and applies to all member accounts — same shape as the three existing SCPs. The `terraform-apply-baseline.yml` workflow auto-applies on merge to main. Because the rollout window for ADR-029 has not yet completed, both `github-actions-terraform` (legacy) and `gh-tf-*` (new) are in the allow-list. After ADR-029 cleanup PR drops the legacy role, a follow-up amendment to this SCP removes that allow-list entry.

### B. Layer 3.5 — State bucket + KMS key policy hardening (DEFERRED)

`aws_kms_key.terraform_state` (in `shared/bootstrap/kms-state.tf`) currently uses `aws:PrincipalOrgID` to allow any org principal `kms:Decrypt` / `kms:Encrypt`. The state bucket has a similar `aws:PrincipalOrgID` condition. Both are correct for the ADR-029 baseline — any account in the org with a valid SSO assumption can read its own state file.

Tightening would replace the broad org-wide condition with an enumerated principal allow-list: `gh-tf-*`, `github-actions-terraform`, `AWSControlTowerExecution`, `aegis-emergency-*`. The marginal value is bounded — cross-account access already requires a valid org principal, which requires SSO + valid role assumption. The escalation path closed by item A is the higher-value primitive.

Deferred to a follow-up PR. Implementation: edit the KMS key policy in `terraform/environments/shared/bootstrap/kms-state.tf` and the bucket policy in `terraform/environments/shared/bootstrap/state-bucket.tf` to add an explicit `Deny` for principals outside the allow-list. The deferral is a sequencing choice, not a downgrade of the decision.

### C. Layer 2.5 — `repository_id` numeric claim binding (DEFERRED)

ADR-029 OQ-4 noted that two of the four `aegis-core-*` CI roles (`cache` and `cognito-integration`) lack the `job_workflow_ref` pin that `ecr` and `frontend` have. This item is the parallel addition: extend all OIDC trust policies — both repos' roles — with the `repository_id` numeric claim. Unlike `repository` (string, mutable on rename), `repository_id` is GitHub's immutable numeric identifier. A trust policy bound to `repository_id` survives a repo rename and rejects a forked-and-renamed-back attack.

Files in scope: `oidc-github*.tf` and `oidc-aegis-core*.tf` in `terraform/environments/management/bootstrap/`, `terraform/environments/shared/bootstrap/`, `terraform/environments/staging/bootstrap/`, `terraform/environments/staging/auth/`, `terraform/environments/staging/edge/`. Aegis-core's CI roles get the same treatment via a parallel cross-repo PR (or, if scoped to ldz, via a no-op upgrade in the trust policy block).

Deferred to a follow-up PR. The defense it provides is against the `repo-renamed` edge case, not the primary fork-PR-OIDC vector ADR-029 closed.

### D. Layer 3 — `aws:ResourceTag/Project` conditions on apply-tier policies (DEFERRED)

Apply-tier role policies (`gh-tf-apply-baseline`, `gh-tf-apply-workload`, `gh-tf-teardown-workload`) currently scope by ARN prefix only — e.g., `arn:aws:iam::*:role/aegis-*`. An attacker who can `iam:CreateRole aegis-evil` (now blocked by item A but historically possible) could create a name-spoofed resource and have the apply-tier role legitimately mutate it.

Adding `Condition: { StringEquals: { "aws:ResourceTag/Project": "landing-zone-lab" } }` on Create / Update / Delete actions would force every mutation to target a resource that carries the project tag. Combined with item A, this makes name-spoofing useless — the attacker would have to create a tagged resource, but `iam:CreateRole` is denied, so the attack does not start.

Caveat: not all AWS services support `aws:ResourceTag` as a condition key on Create — for example, EC2 supports `aws:RequestTag` on the create itself but `aws:ResourceTag` is meaningful only on actions against an existing resource. Per-service support has to be checked at policy-write time.

Deferred to a follow-up PR. The work is not large in line count but requires a per-service audit of condition-key support; bundling it with item A would inflate this PR's review surface.

## Alternatives Considered

### A1. Do nothing — accept Tier 1 (ADR-029) as the wall

Rejected. The privilege-escalation path described in Context is real and well-known in the AWS security literature — see "AWS IAM Privilege Escalation Methods" (Rhino Security Labs, RhinoSecurityLabs/AWS-IAM-Privilege-Escalation). ADR-029 explicitly noted Layer 3 alone bounds blast radius for fork-PR-OIDC but does not close every inner-wall-breach scenario. Accepting Tier 1 as the wall would leave the apply-tier-to-Admin escalation path open. The marginal cost of the SCP is one resource block + the rollout-window allow-list; the value is closing a documented escalation primitive.

### A2. Permission boundary policies on apply roles instead of SCP

Rejected. Permission boundaries are per-role; a compromised role could call `iam:DeleteRolePermissionsBoundary` on itself if that action were permitted, or the boundary policy itself could be modified by `iam:CreatePolicyVersion` / `iam:SetDefaultPolicyVersion` if those actions were permitted. The wall has to live above the role's own scope. SCPs are managed in the management account; apply-tier roles in member accounts cannot reach them. SCP is the structurally correct layer.

### A3. Bundle items A / B / C / D into a single PR

Rejected. The combined diff would touch SCPs (1 file), KMS + bucket policies (2 files), OIDC trust policies (~8 files across both repos), and apply-tier role policies (3 files). Reviewing that surface in one PR is the kind of "too big to review carefully" change `docs/principles/change-review-discipline.md` step 5 ("2 AM readability") explicitly warns against. Per-item PRs preserve the audit trail and the per-item rollback unit.

## Consequences

### Makes easier

- The apply-tier-to-Admin privilege escalation path is closed at the org level. A compromised `gh-tf-apply-baseline` or `gh-tf-apply-workload` can no longer self-promote to Admin via `iam:CreateRole` + `iam:AttachRolePolicy`.
- Tier 2B as a documented unit makes the inner-wall-breach threat model explicit. A reviewer or forker reading ADR-029 → ADR-030 sees the four-item progression and can audit each layer independently.
- The break-glass pattern `aegis-emergency-*` gains a documented namespace via the SCP allow-list. Future incident-only roles do not require an SCP amendment to land.
- CloudTrail `DeniedAccess` on `iam:CreateRole` / `iam:AttachRolePolicy` from an unexpected principal is now a high-signal alert primitive — the only legitimate callers are enumerated.

### Makes harder

- One additional SCP to audit when reviewing org-level changes. The allow-list grows during the ADR-029 rollout window (`github-actions-terraform` + `gh-tf-*` both present) and shrinks when the cleanup PR removes the legacy role.
- A new aegis-prefix IAM-mutating identity (e.g., a future Phase 5+ controller that needs `iam:PassRole`) must either match an existing allow-list pattern or trigger an SCP amendment. The change-review checklist gains a corresponding "does this layer add a new IAM-mutating identity?" line in a future amendment to `docs/principles/change-review-discipline.md`.
- If item D ships, every new resource type added to the apply-tier policies must be audited for `aws:ResourceTag` condition-key support. A new layer that touches an unsupported service either drops the tag condition (weakening boundary) or defers tagging to a post-Create step.
- During the ADR-029 rollout, a `terraform-apply-baseline.yml` run that creates a new IAM role for a layer not yet rolled out can fail with `AccessDenied` if the allow-list misses a principal. Mitigation: the allow-list explicitly covers both legacy (`github-actions-terraform`) and new (`gh-tf-*`) names during the window.

### Risks

- An IAM-mutating runtime caller missing from the allow-list breaks silently — the action fails with `AccessDenied`, the apply or runtime workflow fails, the operator must diagnose. Audit trail: this PR's review pass enumerated Karpenter as the single non-CI runtime caller of the deny-listed actions; future additions (e.g., a service mesh control plane that creates IRSA at runtime) require an explicit SCP amendment.
- The SCP applies to all member accounts including `aegis-staging` and `aegis-prod`. A misconfigured allow-list pattern (typo in `gh-tf-*`) can lock out the apply tier from creating any IAM. Mitigation: the SCP's pattern is matched against ARNs whose shape is verified at PR review time and lands via baseline-apply auto-apply, so a half-broken state is avoided.
- `iam:PassRole` denial across the org has historically tripped non-obvious code paths (e.g., Lambda execution role assignment, ECS task IAM). The current repo has only Karpenter calling PassRole; future services that join the repo must be reviewed against this SCP. The check is part of `docs/principles/change-review-discipline.md` step 1 ("Blast radius") — IAM-mutating callers are a known surface.

## Open Questions

1. **`aegis-emergency-*` — real role or aspirational pattern?** The allow-list reserves the namespace, but no role of this name exists today. The break-glass principle in `docs/principles/break-glass-apply.md` describes the discipline; the role is implicit. Options: (a) leave as aspirational and create the role only when the first incident requires it; (b) materialize a placeholder role with `prevent_destroy = true` and an empty policy now. Resolution preference: (a) — the SCP allow-list documents the intent, no idle resource is needed, and the role's first incarnation should be designed to the specific incident's needs (e.g., scope to a single account, time-bound trust policy, etc.). The principle doc is the source of truth for "when break-glass is allowed"; the role materializes only when needed.

2. **Does `iam:PassRole` denial need a Karpenter-specific test before merge?** Karpenter's `iam:PassRole` call targets `<cluster>-karpenter-node` and is conditioned on `iam:PassedToService = ec2.amazonaws.com`. The allow-list exception (`*-karpenter-controller`) re-permits the action. This was verified by reading `terraform/environments/staging/platform/modules/eks-cluster/karpenter-iam.tf` lines 263-272. A live cold-apply with the SCP attached would be the empirical confirmation; the first apply-baseline run after merge implicitly tests this when the SCP attaches before any Karpenter-driven node provisioning, so the verification is built into the rollout.

## Related

- [ADR-029](029-iam-permission-scope-down.md) — Tier 1; replaced `github-actions-terraform` with the four-role split. ADR-030 is the inner-wall complement.
- [ADR-002](002-region-and-availability-zone-strategy.md) — sibling SCP guardrail; ADR-030 composes with it (a compromised apply-tier token cannot operate outside `eu-central-1` / `eu-west-1` AND cannot create new IAM roles to escape into).
- [ADR-005](005-compliance-framework-iso-27001.md) — the ISO 27001:2022 Annex A.8.2 control reference cited by every SCP in this file.
- [`docs/principles/break-glass-apply.md`](../principles/break-glass-apply.md) — the break-glass discipline that motivates the `aegis-emergency-*` allow-list namespace.
- [`docs/principles/change-review-discipline.md`](../principles/change-review-discipline.md) — the 5-step pre-merge checklist that gains an implicit "new IAM-mutating identity?" line via ADR-030.
- [aegis-core#112](https://github.com/BinHsu/aegis-core/issues/112) and [ldz#170](https://github.com/BinHsu/aegis-aws-landing-zone/issues/170) — Layer 0 cross-repo coordination, the external wall this Tier 2B work complements.

## Appendix A — Implementation Pointer

Item A ships as a single new resource pair in `terraform/environments/management/scps/main.tf`:

- `aws_organizations_policy.deny_iam_privilege_escalation` — the SCP definition, ~50 lines including header banner.
- `aws_organizations_policy_attachment.deny_iam_privilege_escalation` — attached to `local.root_id` (the org root), matching the existing three SCPs' attachment shape.

The file's existing structure (header banner + `data "aws_organizations_organization" "current"` + `local.root_id` + three SCP blocks) is preserved; the new block is appended after `deny_leave_org`. No other files are modified by this PR.
