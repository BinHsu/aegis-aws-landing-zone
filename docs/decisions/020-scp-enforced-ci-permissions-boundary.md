# 020. SCP-Enforced Permissions Boundary for the CI Apply Tier

## Status

Accepted (2026-07-07, decided by Bin). Proposed and accepted the same day; the
three implementation sub-choices (OQ-1..3, see Decision) were decided by Bin
before acceptance. Implementation follows the D4 sequencing.

**Supersedes [ADR-015](015-permission-boundary-hardening.md) §Alternatives A2
only** (the rejection of permission boundaries). This is a partial supersession:
ADR-015 Item A (the `deny-iam-privilege-escalation` SCP) remains in force and is
extended, not replaced, by this ADR. ADR-015's Status line carries the pointer
note; its body stays untouched per the README convention.

Resolves issue #313 ([HIGH] CI apply-tier role has no permissions boundary; SCP
escalation guard exempts it by name).

## Context

### The gap ADR-015 Item A left open

ADR-015's SCP denies IAM-mutating actions org-wide, then exempts
`arn:aws:iam::*:role/gh-tf-*` **by name** (`ArnNotLike` on `aws:PrincipalArn`).
The exemption is load-bearing: `gh-tf-apply-baseline` legitimately creates IAM
roles (the OIDC roles, break-glass, its own in-place updates). But a name-based
exemption cannot constrain what the exempted identity *does* with its IAM
powers. An attacker holding `gh-tf-apply-baseline` — or anything able to act as
a `gh-tf-*`-named role — can still run the escalation ADR-015's own Context
documents:

```
iam:CreateRole (aegis-evil)
  → iam:AttachRolePolicy (AdministratorAccess)
    → sts:AssumeRole
      → org-account admin
```

The SCP watches the *caller's name*, not the *created identity's ceiling*. The
review finding (#313) is that no `permissions_boundary` exists anywhere in the
codebase, so nothing caps what a CI-created role can ever do.

### Why ADR-015 §A2 rejected boundaries — and why that objection no longer holds

ADR-015 §Alternatives A2 rejected permission boundaries with this reasoning
(quoted):

> "Permission boundaries are per-role; a compromised role could call
> `iam:DeleteRolePermissionsBoundary` on itself if that action were permitted,
> or the boundary policy itself could be modified by `iam:CreatePolicyVersion`
> / `iam:SetDefaultPolicyVersion` if those actions were permitted. The wall has
> to live above the role's own scope."

A2 evaluated boundaries **as a role-layer control** — self-imposed, therefore
self-removable. The objection is correct for that design and this ADR does not
dispute it. What A2 did not evaluate is the AWS-canonical composition:
**boundaries required and protected at the SCP layer**. The SCP — which apply
roles cannot reach, exactly as ADR-015 Item A established — denies role
creation *without* the boundary, denies stripping the boundary, and denies
mutating the boundary policy document. Every self-removal path A2 named is
closed by the same layer A2 said the wall must live at. The wall *is* above the
role's scope; the boundary is merely what the wall forces onto every identity
the CI tier mints. This satisfies A2's own requirement rather than
contradicting it — hence supersession of §A2 alone, not of ADR-015.

### What the boundary adds that the name-exemption cannot

With the boundary enforced, `iam:CreateRole aegis-evil` +
`AttachRolePolicy(AdministratorAccess)` still succeeds *as API calls* — but
`aegis-evil`'s effective permissions are the **intersection** of
`AdministratorAccess` and the boundary. The boundary contains no escalation
primitives, so the escalation mints a role no more powerful than the CI tier
already is. The primitive is dead regardless of what the created role is named
or what policies are attached to it.

## Decision

### D1. Boundary policy: `aegis-landing-zone-aws-ci-boundary`

A customer-managed IAM policy, created in **every account** by each
`*/bootstrap` layer. The name follows the CLAUDE.md repo-name-prefix carve-out
for AWS-account-global namespaces (IAM policies are shared across sibling
repos; `aegis-landing-zone-aws-` is the collision-free prefix).

The boundary is attached (`permissions_boundary` attribute) to every
`aws_iam_role` this repository manages. Survey of the actual CI-managed role
inventory on `main` (see Appendix A for the per-role permission basis):

| Role | Accounts | Permission character today |
|---|---|---|
| `gh-tf-plan` | all 7 | read-only API surface + scoped state R/W + KMS via S3 |
| `gh-tf-apply-baseline` | all 7 | `iam:*` on project prefixes, alias, SLR, S3 state, KMS, tag, budgets; + IPAM/RAM (shared); + organizations/SSO/identitystore/GuardDuty/SecurityHub-delegation/events/sns (management) |
| `aegis-emergency-break-glass` | all 7 | `iam:*` on project prefixes, IAM read-all, KMS read+decrypt, SSM read; + organizations read/SCP manage + SSO read (management) |
| `gh-tf-apply-deployment` | deployment | **`AdministratorAccess`** (break-glass-seeded reality; tightening already documented as deferred hardening in its file header) |

**Boundary document shape** — allow by service namespace, deny the escalation
floor:

- **Allow**: the union of service namespaces the roles above legitimately use:
  `iam`, `s3`, `kms`, `ec2` (IPAM + Describe), `ram`, `tag`, `budgets`,
  `events`, `sns`, `organizations`, `sso`, `identitystore`, `guardduty`,
  `securityhub`, `ssm`, `sts`, `ecr` *(per OQ-2, decided by Bin 2026-07-07;
  exact platform surface verified pre-PR-1 — see D4)*. The boundary
  is the outer cap; fine-grained scoping stays in each role's own policy
  (ADR-014). Action-enumerating the boundary would duplicate ADR-014 at a
  second layer and break on every legitimate surface addition.
- **Explicit Deny** (wins over every Allow; the non-negotiable floor):
  - `iam:DeleteRolePermissionsBoundary` / `iam:DeleteUserPermissionsBoundary` —
    a bounded identity can never strip a boundary, including its own.
  - `iam:PutRolePermissionsBoundary` unless `iam:PermissionsBoundary` equals
    the Aegis boundary ARN — no swapping to a permissive boundary.
  - `iam:CreateRole` / `iam:CreateUser` unless `iam:PermissionsBoundary` equals
    the Aegis boundary ARN — the boundary is **self-propagating**: any role a
    bounded role creates is itself bounded. This clause is what partially
    compensates the management-account SCP escape (see Consequences → Risks).
  - `iam:CreatePolicyVersion` / `iam:SetDefaultPolicyVersion` /
    `iam:DeletePolicy` / `iam:DeletePolicyVersion` on
    `arn:aws:iam::*:policy/aegis-landing-zone-aws-ci-boundary` — a bounded
    identity cannot rewrite the boundary document.

### D2. SCP statement S1 — `DenyUnboundedRoleCreateByCi`

Added to `deny-iam-privilege-escalation` in
`terraform/environments/management/scps/main.tf`. Denies, **for callers
matching `arn:aws:iam::*:role/gh-tf-*` only** (`ArnLike` on
`aws:PrincipalArn` — deny-scoped-to, not deny-all-except):

- `iam:CreateRole` where `iam:PermissionsBoundary` `StringNotEquals` the Aegis
  boundary ARN;
- `iam:PutRolePermissionsBoundary` where `iam:PermissionsBoundary`
  `StringNotEquals` the Aegis boundary ARN;
- `iam:DeleteRolePermissionsBoundary` unconditionally.

**Why deny-scoped-to-`gh-tf-*`, and why break-glass needs no carve-out here.**
S1 binds the *caller*, and its principal scope is exactly the CI tier. Every
other identity — `aegis-emergency-*`, `AWSControlTowerExecution`,
`stacksets-exec-*`, `*-karpenter-controller`, SSO sessions — is outside S1's
scope by construction, not by exemption. This matters operationally: the
cold-bootstrap flow (Runbook 002; PRs #275/#278) has break-glass **seeding**
`gh-tf-*` roles after a state clear, and CI adopting them via gated `import`
blocks. Under S1 that seeding is untouched — the seeding caller is
`aegis-emergency-break-glass`, not a `gh-tf-*` role. A boundary-less seeded
role is then converged by CI's first apply: Terraform's `permissions_boundary`
attribute update is `iam:PutRolePermissionsBoundary` **to the correct ARN**,
which S1 allows even for `gh-tf-*` callers. The deny-scoped-to shape is also
future-proof: a new legitimate IAM-mutating identity never trips S1 by
default, whereas a deny-all-except shape would demand an exemption-list
amendment per identity (the exact failure mode #319 flags on the base
statement).

**Technical note — `iam:PermissionsBoundary` condition-key coverage.** The
condition key exists on `iam:CreateRole`, `iam:CreateUser`,
`iam:PutRolePermissionsBoundary`, and `iam:PutUserPermissionsBoundary`. It does
**not** exist on `iam:AttachRolePolicy` or `iam:PutRolePolicy`, so S1 cannot
(and does not try to) condition those. That is sufficient: once the boundary is
forced on at `CreateRole`, attaching `AdministratorAccess` afterwards yields
effective permissions = attached-policy ∩ boundary. The escalation is neutered
at creation time; policy attachment to an already-bounded role is harmless by
construction.

### D3. SCP statement S2 — `ProtectBoundaryPolicy`

Denies `iam:CreatePolicyVersion`, `iam:SetDefaultPolicyVersion`,
`iam:DeletePolicy`, `iam:DeletePolicyVersion` on
`arn:aws:iam::*:policy/aegis-landing-zone-aws-ci-boundary` for **all
member-account principals except `arn:aws:iam::*:role/aegis-emergency-*`**
(`ArnNotLike`).

- **No `gh-tf-*` exemption, deliberately.** A CI role that can rewrite its own
  boundary document defeats the entire design — S2 exists precisely so the
  bounded tier cannot move its own ceiling. Legitimate boundary evolution
  (adding a service namespace when the fabric grows a surface) therefore does
  **not** flow through the normal CI apply path; it flows through the
  break-glass ceremony below or an SCP-window change (see Consequences → Makes
  harder).
- **The `aegis-emergency-*` exemption is the one explicit break-glass carve-out
  this design needs, and it is a lockout-prevention measure.** IAM policies are
  account-local: management principals cannot reach into a member account to
  repair them. Without this exemption, an over-tight or corrupted boundary
  document — which fails every CI `CreateRole` in that account — would be
  unrepairable in-account, and the only recovery would be org-admin detaching
  the whole `deny-iam-privilege-escalation` SCP at the root: a policy bug
  converted into a mandatory org-root ceremony that also drops the base
  escalation wall for every account while detached. With the exemption, repair
  follows the existing break-glass discipline
  (`docs/principles/break-glass-apply.md`, trigger §2 "a bad SCP or IAM-trust
  change has denied the CI role itself"): PR-concurrent, incident entry,
  main-catches-up-same-session. The ultimate backstop remains org-admin SCP
  detach from the management account, which no member-account compromise can
  reach.

### D4. Rollout — two PRs, strictly ordered

Bundling the boundary and the SCP into one change is a lockout hazard: if the
SCP lands before the boundary policy exists in an account, CI's next
`CreateRole` there references a nonexistent boundary ARN and fails. Ordering
(same per-item logic as ADR-015's A3):

0. **Pre-PR-1 (required, per OQ-2 decision)** — verify the platform CI's
   actual service surface against `aegis-platform-aws` `deployment-ecr.tf`
   (what `gh-tf-apply-deployment` executes when platform CI assumes it) and
   fold every namespace found into the boundary allow-list. PR-1 must not
   open until this survey is done.
1. **PR-1 — boundary + attachments.** `aws_iam_policy.ci_boundary` in every
   `*/bootstrap` layer; `permissions_boundary` added to every `aws_iam_role` in
   the inventory above. Applied via the normal baseline path. Verification
   gate: a full-matrix green apply **and** a subsequent all-green scheduled/plan
   cycle proving no role lost a permission it uses (the boundary must be a
   strict superset of current legitimate behavior — if any apply fails
   AccessDenied, the boundary allow-list is missing a namespace and PR-2 must
   not land).
2. **PR-2 — SCP S1 + S2.** Only after PR-1 is applied in **all** member
   accounts.

**Cold-start note** (Runbook 002 flow): on a state-cleared or fresh account
where PR-2's SCP is already attached at the org root, the boundary policy must
exist before CI can create any role. Break-glass can create it:
`iam:CreatePolicy` is not in any deny list (S2 protects *mutation* of the
existing document, and break-glass is exempt from S2 anyway), and the policy
name matches the `policy/aegis-*` resource scope of break-glass's
`IamMutationOnProjectRoles` Sid. Runbook 002 gains a step: "create/verify
`aegis-landing-zone-aws-ci-boundary` before seeding `gh-tf-*` roles; attach the
boundary to seeded roles" (attachment at seed time is hygiene, not a hard
requirement — CI converges it, per D2).

### Sub-choices — all three decided by Bin, 2026-07-07

- **OQ-1 — one boundary document or per-tier variants.** A single org-uniform
  document must include the management-only namespaces (`organizations`, `sso`,
  `identitystore`, `guardduty`, `securityhub`) which workload-account roles
  never use — wider than necessary in 6 of 7 accounts, but one document to
  audit and zero drift between variants. Per-tier variants (management vs
  member) are tighter but double the maintenance and the cold-start surface.
  **Decided by Bin 2026-07-07: single org-uniform document.** The extra
  namespaces carry no escalation primitive and the deny floor is identical
  either way.
- **OQ-2 — `gh-tf-apply-deployment` and its `AdministratorAccess`.** This role
  is CI-created, so S1 forces the boundary onto it, and the boundary then
  de-facto scope-downs its admin attachment to the boundary's allow-list — a
  security *win*, but it breaks the platform repo's shared-registry management
  if the allow-list misses a namespace platform CI uses (`ecr` at minimum).
  Options were: (a) include `ecr` (plus verified platform surface) in the
  boundary and let the boundary be the promised tightening; (b) do the role's
  own deferred policy tightening first, then boundary.
  **Decided by Bin 2026-07-07: option (a).** The boundary includes `ecr` plus
  the verified platform surface. The cross-repo verification against
  `aegis-platform-aws` `deployment-ecr.tf` is a **required pre-PR-1 step**
  (see D4). Tightening `gh-tf-apply-deployment`'s own role policy remains a
  follow-up outside this ADR's rollout.
- **OQ-3 — attach the boundary in the management account too.** Management is
  outside SCP reach, so attachment there is Terraform-driven only — but once
  attached, the boundary's own deny floor (D1) blocks self-stripping even
  without the SCP. Skipping management would keep its roles boundary-less for
  zero benefit.
  **Decided by Bin 2026-07-07: yes — attach uniformly in all 7 accounts.**
  The boundary's own deny floor is the protection in management.

## Alternatives Considered

### 1. Keep ADR-015 Item A as-is (name-based exemption only)

Rejected — this is the reviewed finding itself. The name-based exemption
cannot constrain what an exempted identity creates; the escalation path stays
open exactly as ADR-015's Context describes.

### 2. Tighten the name exemption instead (split `gh-tf-apply-*` from
`gh-tf-plan-*`, bind exemptions to account IDs)

Narrows the caller set but does not close the primitive: the apply role, by
design, keeps `iam:CreateRole` + `iam:AttachRolePolicy`, so a compromised apply
role still escalates. Worth doing independently as #319's fix; not a substitute
for the boundary.

### 3. Role-layer boundary without SCP enforcement (ADR-015 §A2's strawman)

Rejected for the reasons A2 gave — self-removable. This ADR exists because the
SCP-enforced composition answers that objection; the role-layer-only variant
remains rejected.

### 4. Deny-all-except shape for S1 (org-wide boundary requirement with an
exemption list)

The shape #313's remediation sketch implies. Rejected: it would bind
break-glass, Control Tower, StackSets, and Karpenter, each needing an
exemption entry — and an exempted-by-name list is the pattern this ADR is
retiring. Worse, it would deny break-glass's cold-start seeding of `gh-tf-*`
roles (break-glass does not attach boundaries today), turning a state-recovery
incident into a lockout. Deny-scoped-to-`gh-tf-*` binds exactly the tier whose
escalation we are closing and nothing else.

## Consequences

### Makes easier

- The `CreateRole → AttachRolePolicy(AdministratorAccess) → AssumeRole`
  escalation from a compromised CI identity is closed in every member account —
  the minted role is capped by the boundary no matter its name or attachments.
- The boundary is self-propagating (D1 deny floor): bounded roles can only
  create bounded roles, transitively.
- `gh-tf-apply-deployment`'s `AdministratorAccess` gets a real ceiling (OQ-2,
  decided (a)), delivering the first slice of that file's documented deferred
  hardening; the role-policy tightening itself stays a follow-up.
- Denied `iam:*` events from boundary enforcement are high-signal detective
  input, same class ADR-016 already alerts on.

### Makes harder

- **Boundary evolution is a ceremony, by design.** Adding a service namespace
  to the boundary (new fabric surface) cannot ride the normal CI apply — S2
  blocks CI from mutating the boundary document. The paths are: break-glass
  apply under `docs/principles/break-glass-apply.md` obligations, or a
  temporary SCP-window change reviewed like any SCP change. Expected frequency:
  rare (the fabric's surface is deliberately static, ADR-001).
- Every new `aws_iam_role` in this repo must set `permissions_boundary`, or CI
  apply fails at creation. The change-review checklist
  (`docs/principles/change-review-discipline.md`) gains this line when PR-1
  lands.
- Runbook 002 gains the boundary-before-seeding step (D4).

### Risks / residuals — stated honestly

- **The management account escapes the SCP wall entirely.** SCPs bind member
  accounts only (`scps/main.tf` line 13). Covered: security, logarchive,
  shared, deployment, staging, prod, and every future vended account. Escapes:
  management (186052668286) — including its own `gh-tf-apply-baseline` /
  `gh-tf-plan`. This is **not a regression**: ADR-015 Item A never bound
  management either; the escalation path there has always been outside SCP
  reach. Partial compensation from this ADR: per OQ-3 (decided) the boundary is
  attached in management too, and its own deny floor blocks self-stripping — the
  residual narrows to "a management principal with `iam:*` outside the
  boundary's reach mutates the role's identity policy," which changes nothing
  about the boundary cap. Standing compensating controls in management: OIDC
  trust pinned to `repository_id` + `sub: ref:refs/heads/main` with fail-closed
  `infra_repo_id` (ADR-014 / ADR-019), GitHub branch protection (Layer 0),
  detective controls on failed OIDC assumption and denied-access events
  (ADR-016), root MFA + cold storage (Runbook 001 Part 3).
- **A missing namespace in the boundary breaks CI loudly, not silently** —
  apply fails `AccessDenied`. PR-1's verification gate exists for this; the
  repair path is the D3 ceremony. This is the same failure-mode class ADR-015
  already accepted for the SCP allow-list.
- **S2's break-glass exemption is a trust concentration**: `aegis-emergency-*`
  can rewrite the boundary document in-account. Bounded by the role's trust
  policy (local-account PlatformAdmin SSO only, 1-hour sessions) and the
  break-glass discipline's audit obligations. The alternative (no exemption)
  trades this for the org-root-detach lockout described in D3 — worse.
- Boundary-less window on seeded roles: between break-glass seeding and CI's
  first converging apply, a seeded `gh-tf-*` role runs unbounded (S1 caps what
  it *creates*, so the escalation primitive is still closed; the window only
  widens its direct action surface). Runbook hygiene (attach at seed time)
  shrinks it to zero.

## Related

- [ADR-014](014-iam-permission-scope-down.md) — the CI role scope-down; the
  boundary is the ceiling above those per-role policies.
- [ADR-015](015-permission-boundary-hardening.md) — Item A's SCP is extended by
  S1/S2; §Alternatives A2 is superseded by this ADR.
- [ADR-016](016-detective-controls.md) — alerts on the denied-event classes
  S1/S2 produce.
- [ADR-019](019-budgets-iac-and-oidc-fail-closed.md) — the fail-closed OIDC
  trust that is part of the management-account compensating-control set.
- [`docs/principles/break-glass-apply.md`](../principles/break-glass-apply.md)
  — the ceremony governing S2's `aegis-emergency-*` exemption and boundary
  repair.
- [`docs/runbooks/002-cold-account-bootstrap.md`](../runbooks/002-cold-account-bootstrap.md)
  — gains the boundary-before-seeding step (D4).
- Issue #313 (this finding), #319 (name-based exemption tightening — sibling,
  not substitute), #312 (review epic).

## Appendix A — Permission basis for the boundary allow-list

Union of service namespaces actually used by CI-managed roles on `main`
(source files: `terraform/environments/*/bootstrap/oidc-github-plan-role.tf`,
`oidc-github-baseline-role.tf`, `aegis-emergency-role.tf`,
`deployment/bootstrap/oidc-github-apply-deployment-role.tf`):

| Namespace | Used by | Evidence (Sid) |
|---|---|---|
| `iam` | apply, break-glass, plan (read) | `IamScoped`, `IamMutationOnProjectRoles`, `IamServiceLinkedRoleCreate`, `AccountAliasManagement` |
| `s3` | apply, plan | `StateBucketFull`/`StateBucketCrossAccount`, `ReadStateObject`, `WriteStateLockSuffixOnly` |
| `kms` | apply, plan, break-glass | `KmsLocal`, `KmsForStateAndSsm`, `KmsReadAndDecrypt` |
| `ec2` | apply (shared: IPAM), all (Describe) | `IpamMutate`, `IpamServiceLinkedRole`, `ReadOnlyAwsApiSurface` |
| `ram` | apply (shared) | `RamFull` |
| `tag` | all | `TagApi`, `StsAndTagRead` |
| `budgets` | apply | `BudgetsScoped` |
| `events` | apply (management) | `EventsForDetectiveRule` |
| `sns` | apply (management) | `SnsForDetectiveTopic` |
| `organizations` | apply + break-glass (management) | `OrganizationsFull`, `OrganizationsRead`, `OrganizationsScpManage` |
| `sso`, `identitystore` | apply + break-glass (management) | `SsoAndIdentityStoreFull`, `SsoRead` |
| `guardduty`, `securityhub` | apply (management) | `GuardDutyOrgAdminDelegation`, `SecurityHubOrgAdminDelegation` |
| `ssm` | break-glass (read) | `SsmReadProject` |
| `sts` | all | trust policies, `StsAndTagRead` |
| `ecr` | `gh-tf-apply-deployment` (OQ-2, decided (a)) | via `AdministratorAccess` today; exact surface verified against `aegis-platform-aws` `deployment-ecr.tf` in the required pre-PR-1 step (D4) |

The boundary allows these namespaces wholesale and relies on ADR-014's
per-role policies for fine-grained scoping; the boundary's job is the deny
floor in D1, not a second copy of the role policies.
