<!-- session-close-review: allowed-triggers list + forbidden-triggers list + incident-recording obligation still match the compensating controls that actually exist -->
# Break-glass local apply discipline

> **Scope**: this doc governs when a Terraform `apply` from a local workstation (bypassing the CI path in `.github/workflows/terraform-apply-*.yml`) is allowed. It complements [ADR-009](../decisions/009-lifecycle-teardown-strategy.md) (lifecycle + teardown) and the operational rules in [CLAUDE.md](../../CLAUDE.md).

## Default position

**Default: local `terraform apply` against shared AWS state is FORBIDDEN.**

Every apply goes through one of:
- `.github/workflows/terraform-apply-baseline.yml` — auto-applies on merge to main, for baseline layers only
- `.github/workflows/terraform-apply-workload.yml` — `workflow_dispatch`-only, approval-gated, for cost-incurring layers

The single-path rule exists because:

1. **Audit trail**: GitHub Actions records who dispatched, who approved, what commit was applied. A local apply leaves no such record outside the operator's shell history.
2. **Drift integrity**: main branch is the single source of truth for deployed state. Local apply of a feature-branch state violates this invariant.
3. **OIDC security posture**: CI uses short-lived OIDC tokens. Local apply uses long-lived SSO creds (shorter-lived than static keys but still longer than CI's minutes).
4. **Compensating control for bugs**: CI runs the full test suite + Checkov + provider-version validation before applying. Local apply skips all of it.

"Drift is a bug" is a load-bearing design principle of this repo ([design-narrative.md §"The 30-second version"](../design-narrative.md)). Local apply is the highest-frequency source of drift in every ops team that allows it.

## When break-glass IS allowed

Local apply is acceptable — with recorded compensating controls — in exactly these scenarios:

### 1. CI itself is broken

- GitHub Actions is in an outage (status.github.com red)
- The runner's IAM OIDC trust relationship has drifted and deploy is needed to restore any cluster before the trust can be repaired
- The Terraform state backend is corrupted and recovery requires `terraform state rm` + manual restore (cannot be done from CI's ephemeral runner)

**Compensating control**: Incident post-mortem in `docs/incidents.md`, with "Detection" section naming the CI outage / the specific breakage that forced the path.

### 2. Mid-session AWS outage or state drift that would cost > $10/hr to let persist

- NAT gateway or EKS control plane is running, a bug was discovered, and re-triggering CI would cost more than the bug itself
- State is half-applied and `terraform destroy` through CI would fail-loop on the broken state

**Compensating control**: A PR that captures the code delta MUST be opened within the same session. Main branch must catch up before the session closes. The PR description cross-references this doc § "When break-glass IS allowed" and names which trigger applied.

### 3. Emergency response to security incident

- Credential revocation, SCP tightening, firewall blocks that cannot wait for CI's 5–15 minute turnaround
- SCP denies the CI role itself (contradiction resolution)

**Compensating control**: Incident post-mortem AND a retrospective on whether the CI path can be hardened to handle this automatically next time.

## When break-glass is NOT allowed (common mistakes)

All of these are **forbidden** and produce a drift incident if committed:

- "I want to see this change fast" — not allowed. If CI is slow, fix CI.
- "The PR hasn't merged yet but I have SSO creds" — not allowed. Merge the PR.
- "It's just a docs-only change" — irrelevant; docs don't need apply.
- "The reviewer is AFK" — not allowed. Wait, or assign another reviewer, or accept the session is paused.
- "I'll push the PR after" — a PR opened after the apply is a record of drift being corrected, not a license to apply locally. The PR must exist *before* or *concurrently with* the apply to count as compensating.
- "It's the DR region, nobody's watching" — doubly not allowed. DR regions are the hardest to recover when drift is introduced quietly.

## Compensating controls required for every break-glass event

Regardless of which scenario above, a break-glass apply incurs these obligations:

1. **Open a PR with the applied code delta** — before or during the apply. No drift-first / PR-later.
2. **Commit to main via CI within 1 session-close** — main catches up via the normal squash-merge path. Target: same day.
3. **Write an incident entry** in `docs/incidents.md` — use the standard Symptom/Root cause/Detection/Resolution/Prevention/Lessons format. The Resolution section should include the exact `terraform apply` command and which AWS profile was used.
4. **Reference this doc** in the incident's Resolution or Lessons section — future operators should be able to trace from the incident back to the rule.
5. **Reflect on the Prevention section honestly** — did CI have a gap that made local-apply the least-bad option? If yes, that gap is its own follow-up.

## Operator eligibility

- **Lab tier** (today): only the repo owner (Bin) can break-glass. No delegation; the accountability is not separable from the operator role in a single-operator project.
- **Team tier** (future, aspirational): a named break-glass role in Identity Center with MFA + short-lived session + manual approval by a second engineer. Break-glass access rotates quarterly or upon personnel changes.

The lab-tier position is explicitly not a recommendation for a team environment. At team scale, the "only X can break-glass" rule must be paired with auditable approval by a second human, or the pattern becomes "everyone claims emergency authority."

## Relation to other discipline docs

- [`docs/principles/change-review-discipline.md`](change-review-discipline.md) — the *review-time* gate; this doc is the *apply-time* gate for exceptional cases
- [ADR-009](../decisions/009-lifecycle-teardown-strategy.md) — the workflow split that this doc's default position relies on (baseline auto-apply vs workload dispatch-gated)
- [`docs/incidents.md`](../incidents.md) — where every break-glass event is recorded
- [CLAUDE.md](../../CLAUDE.md) — operational rules at the root; defers to this doc on break-glass specifics

## Forward-looking trigger: when this doc should be revised

- When the team expands past 1 operator — §"Operator eligibility" must be rewritten to match the new org shape
- When prod workloads exist — the "mid-session apply cost" trigger tightens (prod break-glass is more constrained than staging)
- When a non-GitHub CI is added (e.g., Buildkite for air-gap deploys) — the "single-path rule" clause must enumerate the new path
- When any sibling project in the same org adopts the same rule — consolidate into an org-level principle, keep this doc as a link target

*Last updated: 2026-04-20 — initial doc, triggered by Incident 31 (mid-session platform apply failure, local re-apply as compensating speed play). The incident's Lessons section is the first concrete case study of this doc's boundaries.*
