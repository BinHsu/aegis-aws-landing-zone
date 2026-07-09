# 021. CI-Native Cold-Account Bootstrap — Retire Manual Seed + Adopt

## Status

Proposed (2026-07-09). Raised as issue #309 on 2026-07-06 during the LZ-S1
(`security`/`logarchive`, #303) cold-start. **Bin decides acceptance** — this
ADR proposes a design and stages a rollout; it does not itself change any
Terraform.

Three sub-choices — OQ-1 (dedicated role), OQ-3 (`workflow_dispatch` +
approval gate), OQ-7 (keep the script as break-glass fallback) — were
**decided by Bin, 2026-07-09** (recorded in each OQ below). Deciding
sub-choices does not accept the ADR: acceptance and implementation remain a
separate, later decision by Bin. OQ-2, OQ-4, OQ-5, OQ-6 stay open.

Depends on [ADR-020](020-scp-enforced-ci-permissions-boundary.md): a CI-native
bootstrap that mints `gh-tf-*` roles must create them *with* the
`aegis-landing-zone-aws-ci-boundary` attached and must create the boundary
policy in the cold account first (ADR-020 D4 cold-start note). See
Consequences → "Consistency with ADR-020".

## Context

### The current cold-start flow, as it actually runs

A brand-new Control-Tower-vended member account cannot have its first Terraform
`bootstrap/` layer applied by CI, for two independent reasons documented in
[Runbook 002](../runbooks/002-cold-account-bootstrap.md):

1. **CI needs roles that do not exist yet.** The `bootstrap/` layer is what
   *creates* the `gh-tf-plan` / `gh-tf-apply-baseline` roles CI assumes via
   OIDC (ADR-014), plus `aegis-emergency-break-glass` (ADR-015), the GitHub
   OIDC provider, and the account alias. On a cold account none of these
   exist, so the workflows have nothing to assume. The first apply must run
   from credentials that already work on a fresh account — `AWSControlTowerExecution`
   (CT-exec), assumed from the management account.

2. **The state bucket rejects the only role a human can use.** The Terraform
   state bucket policy (`terraform/environments/shared/bootstrap/main.tf`)
   admits only `gh-tf-*` (per-account-scoped), `aegis-emergency-*`, and the
   SSO `PlatformAdmin` permission set. CT-exec is deliberately **not** on that
   allow-list, so a normal S3-backed apply under CT-exec fails on state access
   before it creates anything.

Runbook 002 resolves both with a two-phase, operator-laptop ceremony run by
`scripts/cold-start-bootstrap.sh`:

- **SEED** — `terraform apply` under CT-exec with `backend.tf` moved aside so
  state is local and throwaway. This creates the roles for real in the
  account; the local state is then discarded.
- **ADOPT** — a split-credential apply: the S3 **backend** authenticates as the
  operator's ambient `PlatformAdmin` SSO identity (which *can* write state),
  while the **provider** temporarily assumes CT-exec via a generated
  `*_override.tf`. Run with `-var=adopt_seeded_iam_roles=true`, which flips
  `iam-survivor-import.tf` from *create* to *import* so the eight
  already-existing resources are imported into S3 state rather than
  re-created.

After ADOPT, S3 state matches reality and ordinary CI applies (adopt defaults
to `false`) show no diff.

### What is actually painful

The ceremony works — it is consistent across `prod` (#278) and
`security`/`logarchive` (#303) — but every property that makes it work also
makes it fragile:

- **Laptop-gated and human-credential-gated.** It requires an operator's SSO
  session, a local `terraform`, and two interactive `yes` prompts. There is no
  path to bootstrap an account without a human at a keyboard with the right
  profile.
- **Two state representations for one set of resources.** SEED creates the
  resources under throwaway local state; ADOPT then re-discovers them by
  `import`. The `iam-survivor-import.tf` + `var.adopt_seeded_iam_roles`
  machinery exists *only* to bridge that gap, and its import block must cover
  every resource, not just the roles — easy to under-cover (the runbook calls
  this out explicitly as a footgun).
- **Split-credential subtlety.** ADOPT depends on one profile being able to do
  two different things (assume CT-exec into the target *and* hold PlatformAdmin
  on the state bucket). A narrower profile fails partway.

### "AFT-style" — what this ADR does and does not mean

Issue #309 titles the work "AFT-style". That phrase needs disambiguation,
because this repository already contains a real AFT layer:

- **AWS Account Factory for Terraform (AFT)** — the `aws-ia/control_tower_account_factory/aws`
  module at `terraform/environments/shared/aft/`, committed-but-not-applied as
  **Path B** ([ADR-011](011-account-provisioning-two-path-strategy.md)). AFT
  automates account **creation** (vend an account by merging a request file).
- **This ADR** targets account **configuration** — the `gh-tf-*`-roles-plus-state
  bootstrap that runs *after* an account is vended, regardless of how it was
  vended.

ADR-011's load-bearing separation is that account creation and account
configuration are distinct concerns, and the `bootstrap/` layer is the
**invariant** that runs the same way whichever path created the account.
Therefore **adopting real AFT would not, by itself, eliminate the seed+adopt
ceremony** — AFT hands off a vended account, and that account still hits the
same two chicken-and-eggs on its first `bootstrap/` apply. "AFT-style" here
means "a central, CI-driven mechanism bootstraps each member account", not
"deploy the AFT module". This ADR is orthogonal to Path B and composes with it
(see Alternatives → 2).

### The recursion bottoms out at the management account

One boundary is worth stating up front: the management account's own cold
bootstrap can **never** be CI-native, because at that instant no CI identity
exists anywhere in the org. Runbook 001 (from-zero) bootstraps management by
hand; that is irreducible. Everything below applies to **member** accounts
vended *after* management already holds a CI identity — which is every account
except the first.

## Decision (proposed)

Replace the laptop seed+adopt ceremony with a single CI-driven apply that
bootstraps a cold member account end to end. The design has four parts.

**Framing (confirmed by Bin, 2026-07-09):** what this refactoring eliminates
is *routine* reliance on break-glass-grade manual access for onboarding — a
predictable, recurring event should not require an operator wielding
CT-exec-level credentials by hand. Break-glass itself is untouched: it remains
the emergency repair hatch, and the target state is that it almost never
fires.

### D1. A management-level bootstrap role, assumable by CI via OIDC

Add one **dedicated** role in `management/bootstrap` — `gh-tf-cold-bootstrap`
(per OQ-1, decided by Bin 2026-07-09) — that CI assumes via GitHub OIDC, trust-pinned like every
other `gh-tf-*` role (repo id + `ref:refs/heads/main`, fail-closed per
ADR-019). It holds exactly two cross-account powers the steady-state CI roles
do not:

- **`sts:AssumeRole` on `arn:aws:iam::<member>:role/AWSControlTowerExecution`**
  — the only door into a freshly vended account (ADR-008 hybrid; CT owns
  CT-exec).
- **Write access to the target account's state key in the shared state bucket**
  — so the *same* run that creates the roles also records them in real S3
  state. This requires a state-bucket policy change (D3).

This role is the CI-assumable equivalent of the human `PlatformAdmin` identity
that ADOPT uses today.

### D2. One apply, real S3 state from the start — no seed, no import

The bootstrap workflow runs a single `terraform apply` against the member
account's `bootstrap/` layer with:

- the **S3 backend** authenticated as `gh-tf-cold-bootstrap` (which D3 puts on
  the allow-list), and
- the **provider** assuming CT-exec into the target account (the only
  credential that works on a cold account).

Because state starts empty and the resources do not yet exist, Terraform
**creates** them and records them in S3 in the same run. There is no throwaway
local state and therefore nothing to `import` afterwards. The apply creates,
in dependency order:

1. `aegis-landing-zone-aws-ci-boundary` (the ADR-020 permissions boundary) —
   **first**, so that
2. the `gh-tf-*` roles are created **with** `permissions_boundary` set (no
   boundary-less window — an improvement over today's SEED, see Consequences),
   alongside the OIDC provider and account alias.

From the next apply onward the account is warm: CI assumes the account's *own*
`gh-tf-apply-baseline` directly (steady-state path, no CT-exec, no
cross-account state write). `gh-tf-cold-bootstrap` is used once per account and
is idle otherwise.

### D3. State-bucket policy admits the bootstrap role for member state keys

Add a statement to `aws_s3_bucket_policy.terraform_state` granting
`gh-tf-cold-bootstrap` write access to member-account state keys during
bootstrap. Scope is an open question (OQ-2): the tension is between one
management role that can write *any* account's state key (operationally simple,
broad blast radius) versus a per-onboarding-scoped grant (tighter, more moving
parts). CT-exec is **not** added to the allow-list — the provider uses it only
for resource operations, never for state.

### D4. Retire the seed/adopt-only machinery once CI-native is proven

After CI-native bootstrap succeeds on at least one real cold account
(Migration → Stage 3), remove the code whose only reason to exist was the
throwaway-state-then-import bridge:

- `iam-survivor-import.tf` and `var.adopt_seeded_iam_roles` in every
  `*/bootstrap` layer.
- `scripts/cold-start-bootstrap.sh` is **downgraded to a documented
  break-glass fallback** for when CI is unavailable (per OQ-7, decided by Bin
  2026-07-09: keep it until CI-native is proven at Stage 3; only then retire
  its role as the routine path).
- Runbook 002 is rewritten around the CI-native path, keeping the manual
  ceremony as the break-glass appendix.

## Alternatives Considered

### 1. Status quo — keep the manual seed+adopt ceremony

Rejected as the target state, but it stays as the fallback until CI-native is
proven (Migration is staged precisely so status quo remains the safety net).
The ceremony is correct and battle-tested; its cost is that every new account
needs an operator, a laptop, and two interactive applies, and that the
`iam-survivor-import.tf` import-coverage footgun is load-bearing forever. #309
raised this because that cost recurs on every future member account.

### 2. Adopt real AWS Control Tower AFT (activate ADR-011 Path B)

Rejected as a *substitute*, though not incompatible. AFT automates account
**creation**, not the `bootstrap/` configuration layer — the invariant per
ADR-011. A vended-by-AFT account still hits both chicken-and-eggs on its first
`bootstrap/` apply, so AFT alone does not retire seed+adopt. AFT *does* offer
a global-customizations hook where a bootstrap step could run, but activating
AFT costs ~$10–15/month (ADR-011) for a capability used a handful of times, and
the project is deliberately Path A (6 accounts, single operator). This ADR
delivers the CI-native property #309 wants **without** paying for AFT, and
composes with Path B later: if AFT is ever activated, `gh-tf-cold-bootstrap`
is what its customization step would invoke (OQ-6).

### 3. Hybrid — CI-native as the default path, seed+adopt as break-glass

This is effectively the *staged* form of the Decision, not a rival. CI-native
becomes the normal path; the manual script survives (downgraded) as the
break-glass path for when CI itself is the thing that is broken — the same
posture ADR-020 D3 takes for boundary repair. OQ-7 (decided by Bin
2026-07-09) confirms exactly this shape: the script is kept as a documented
break-glass fallback until CI-native is proven at Stage 3. Captured here so
the choice is explicit rather than implied.

### 4. Add CT-exec to the state-bucket allow-list and skip the bootstrap role

Rejected. It would let CT-exec write state directly, collapsing the flow to a
single CT-exec apply with no split credentials — superficially the simplest
option. But CT-exec is Control Tower's role, broadly powerful and present in
every account; granting it state-bucket write widens a Control-Tower-owned
identity's reach into Terraform state across the org, which the current policy
deliberately withholds. A purpose-built, OIDC-only, trust-pinned bootstrap role
(D1) is the least-privilege choice and keeps the state-writer inside the
project's own identity model.

## Consequences

### Makes easier

- **No operator laptop.** A cold account is bootstrapped by a CI run — SSO
  session, local Terraform, and interactive prompts all disappear from the
  critical path.
- **One state representation.** Resources are created and recorded in S3 in the
  same apply. `iam-survivor-import.tf`, `var.adopt_seeded_iam_roles`, and the
  import-coverage footgun retire with D4.
- **No boundary-less window.** The bootstrap apply creates roles *with* the
  ADR-020 boundary attached from birth, closing the "boundary-less seeded role
  until CI's first converging apply" residual ADR-020 lists (Risks →
  boundary-less window).
- **Auditable trigger.** Cold bootstrap becomes a workflow run with a commit,
  logs, and a GitHub environment approval gate (per OQ-3, decided) — a
  cleaner audit trail than a laptop session.

### Makes harder / new obligations

- **`gh-tf-cold-bootstrap` is a high-value identity.** It can assume CT-exec
  into member accounts and write member state keys. Its trust policy must be
  pinned exactly like the other `gh-tf-*` roles, and it lives in the
  management account — which SCPs do not reach (ADR-020 Risks). Compensating
  controls are the same management-account set ADR-020 relies on (OIDC trust
  pinning, branch protection, detective controls on failed/denied assumptions).
- **A new cross-account state-write grant.** D3 widens the state-bucket policy.
  The scope decision (OQ-2) directly sets this identity's blast radius.
- **Bootstrap is a distinct workflow from steady-state apply.** The cold path
  (management role + CT-exec provider) and the warm path (account's own
  `gh-tf-apply-baseline`, no provider assume) are different credential shapes.
  Per OQ-3 (decided by Bin 2026-07-09) they are expressed as a separate
  `workflow_dispatch` bootstrap workflow with an approval gate — one more
  workflow file to maintain, in exchange for onboarding staying a visible,
  gated event rather than a branch inside routine applies.

### Consistency with ADR-020 (dependency, not optional)

- The bootstrap apply **must** create `aegis-landing-zone-aws-ci-boundary`
  before any role, and set `permissions_boundary` on every `gh-tf-*` role it
  creates (ADR-020 D1/D4).
- Inside the target account the resource-creating caller is **CT-exec**, not a
  `gh-tf-*` role. ADR-020 SCP **S1 is deny-scoped to `gh-tf-*` callers**, so
  S1 does not fire during bootstrap — the same reason ADR-020 D2 gives for
  break-glass seeding being untouched. The bootstrap therefore succeeds under
  S1, and because it attaches the boundary anyway, the account is compliant the
  moment it is warm.
- If ADR-020 PR-2 (the SCP) is already attached org-wide when an account is
  vended, the boundary policy must still be created before roles — which D2
  does by ordering. This matches the "Cold-start note" ADR-020 already added to
  D4.

### Risks / residuals — stated honestly

- **CT-exec coupling.** The provider path depends on Control Tower's CT-exec
  role existing and being assumable from management. This is already true for
  seed+adopt and is consistent with the ADR-008 hybrid, but it does couple cold
  bootstrap to Control Tower's identity.
- **Management stays outside SCP reach.** `gh-tf-cold-bootstrap` lives in
  management; nothing in this ADR changes the standing ADR-020 residual that
  management escapes the SCP wall. The boundary's own deny floor (attached in
  management per ADR-020 OQ-3) is the in-account protection.
- **First real run is the test.** `terraform validate` cannot prove the
  cross-account trust chain, the state-bucket grant, and the CT-exec provider
  compose correctly — only a real cold account can (the same limitation ADR-011
  notes for Path B). Migration Stage 2 exercises it against a throwaway vended
  account before a real one; status quo remains the fallback until Stage 3.

## Migration path (staged, reversible until the last stage)

**Stage 0 — build the bootstrap identity, do not use it.** Add
`gh-tf-cold-bootstrap` to `management/bootstrap` (D1) with the ADR-020 boundary
attached; add the state-bucket grant (D3). No behavior change — the role exists
but no flow uses it yet. Status quo is untouched.

**Stage 1 — build the CI-native apply path.** Add the dedicated
`workflow_dispatch` bootstrap workflow with its approval gate (per OQ-3,
decided): OIDC → `gh-tf-cold-bootstrap` → S3 backend as that role + provider
assumes CT-exec. Nothing runs automatically.

**Stage 2 — dry-run on a throwaway account.** Vend a disposable member account
and bootstrap it CI-native end to end. Verify: boundary created first, roles
created bounded, state written to S3, and a subsequent *ordinary* CI apply
(warm path, adopt machinery untouched) shows no diff. Tear the account down.

**Stage 3 — cut over on the next real cold account, then retire.** Use
CI-native bootstrap for the next real member account. Once it is proven on at
least one real account, execute D4: remove `iam-survivor-import.tf` +
`var.adopt_seeded_iam_roles`, downgrade `scripts/cold-start-bootstrap.sh` to
a documented break-glass fallback (per OQ-7, decided), and rewrite Runbook 002
around the CI-native path. This is the first irreversible stage — everything
before it leaves the manual ceremony fully intact as the fallback.

## Sub-choices — OQ-1/3/7 decided by Bin 2026-07-09; OQ-2/4/5/6 open

- **OQ-1 — bootstrap identity: new role or extend an existing one.** A
  dedicated `gh-tf-cold-bootstrap` keeps the two cross-account powers on a
  single-purpose, mostly-idle identity. Extending management's existing
  `gh-tf-apply-baseline` avoids a new role but widens a steady-state role's
  blast radius to include cross-account CT-exec assume + cross-account state
  write. **Decided by Bin 2026-07-09: dedicated `gh-tf-cold-bootstrap` role.**
  Extending the daily apply role would merge cold-start-grade power into a
  standing high-privilege identity — the same disease this ADR treats; a
  dedicated role sits at zero use in steady state, so any invocation is a
  discrete audit event.
- **OQ-2 — state-bucket grant scope.** One statement letting the bootstrap
  role write *any* member account's state key (simple, broad) vs. a grant
  scoped/added per onboarding (tighter, more churn). Sets the role's blast
  radius directly. **Open.**
- **OQ-3 — trigger model.** A dedicated `workflow_dispatch` bootstrap workflow
  with a GitHub environment approval gate (preserves a human-in-the-loop
  equivalent to today's interactive `yes`, appropriate for minting trust
  anchors) vs. a conditional branch inside the main apply workflow (fewer
  files, harder to gate). **Decided by Bin 2026-07-09: dedicated
  `workflow_dispatch` workflow with an approval gate.** Onboarding is a
  low-frequency, high-stakes event; a human approval click is governance, not
  the old disease (the disease was "human does the whole ceremony by hand",
  not "human nods") — and a conditional branch in the main apply would make
  onboarding invisible inside routine applies.
- **OQ-4 — provider credential source.** Assume CT-exec directly (proposed;
  matches today's ADOPT override) vs. introduce a per-account bootstrap role
  that CT-exec seeds first. The latter removes the CT-exec dependency at the
  cost of another chicken-and-egg. *Proposed: CT-exec, as today.*
- **OQ-5 — confirm scope excludes management.** This ADR asserts management's
  own bootstrap stays manual (Runbook 001), being irreducible. Confirm that
  boundary is accepted rather than something to chase. **Open.**
- **OQ-6 — relationship to Path B (real AFT).** If AFT is ever activated, is
  `gh-tf-cold-bootstrap` the identity AFT's global-customizations step invokes,
  or does Path B get its own bootstrap path? Affects whether D1's role is
  designed AFT-aware now or later. **Open.**
- **OQ-7 — keep the manual script as break-glass, or delete it.** Downgrade
  `scripts/cold-start-bootstrap.sh` to a documented break-glass fallback for
  when CI is unavailable (mirrors ADR-020 D3's break-glass posture) vs. delete
  it outright once CI-native is proven. **Decided by Bin 2026-07-09: keep it,
  downgraded to a documented break-glass fallback, until CI-native bootstrap
  is proven on a real account (Stage 3); only then retire it as the routine
  path.**

## Related

- [ADR-020](020-scp-enforced-ci-permissions-boundary.md) — the CI permissions
  boundary and SCP S1/S2 the bootstrap apply must honor (create boundary first;
  create roles bounded; CT-exec caller is outside S1's `gh-tf-*` scope).
- [ADR-011](011-account-provisioning-two-path-strategy.md) — the account
  creation two-path strategy; this ADR configures the invariant `bootstrap/`
  layer regardless of creation path, and composes with Path B (AFT) rather than
  replacing it.
- [ADR-008](008-landing-zone-tooling-control-tower-hybrid.md) — the Control
  Tower + Terraform hybrid that makes CT-exec the door into a cold account.
- [ADR-014](014-iam-permission-scope-down.md) — the `gh-tf-*` OIDC role model
  the bootstrap role joins and trust-pins.
- [ADR-019](019-budgets-iac-and-oidc-fail-closed.md) — the fail-closed OIDC
  trust the bootstrap role inherits.
- [Runbook 002](../runbooks/002-cold-account-bootstrap.md) — the manual
  seed+adopt ceremony this ADR proposes to replace (and rewrite at Stage 3).
- Issue #309 (this proposal), #303 (`security`/`logarchive` cold-start that
  raised it), #278 (`prod` `iam-survivor-import.tf` precedent D4 retires).
