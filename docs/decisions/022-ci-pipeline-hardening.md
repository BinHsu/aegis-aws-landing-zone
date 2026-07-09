# 022. CI Pipeline Hardening — Saved-Plan Apply, Config-Derived Matrix, Policy-as-Code Gate

## Status

Proposed (2026-07-09). Addresses three MED findings from the 2026-07-06
principal-architect review, filed under epic #312: #316 (auto-apply TOCTOU),
#320 (config duplicated across CI matrices / backend.tf), #321 (no policy-as-code
gate). Landed together because all three touch the CI workflow layer.

The human-gate half of #316 is a **behavior change Bin must consciously accept**
(see Decision D1 → "Arming"). Merging this PR wires the workflow to reference a
GitHub Environment; it does not by itself pause any apply.

## Context

The apply pipeline (`terraform-apply-baseline.yml`) auto-applied every layer —
including org-root Organizations + SCPs — with `terraform apply -auto-approve`
and **re-planned at apply time**. The plan a human (or Checkov) reviewed on the
PR was not guaranteed to equal the plan `-auto-approve` computed and applied
after merge (TOCTOU). For the SCP layer, whose blast radius is the whole
organization, an unreviewed auto-apply was the single highest-leverage failure
point in the pipeline (#316).

Account IDs were hand-copied into two workflow matrices (plan + apply) and again
into every `backend.tf` bucket name, while the actual source of truth
(`config/landing-zone.yaml`) shipped into CI as one opaque `LANDING_ZONE_CONFIG`
secret. Every copy could drift from the config silently (#320).

CI asserted guardrail correctness only through `terraform plan` + Checkov + human
review. Checkov tests generic IaC hygiene; nothing asserted the repo-specific
invariants the epic depends on — e.g. "every `gh-tf-*` role carries the Aegis
permissions boundary" (#313) — so a future PR could regress one and merge (#321).

## Decision

### D1 — Saved-plan apply + a human gate on the SCP layer only (#316)

Every apply layer switches from `apply -auto-approve` (fresh re-plan) to the
canonical two-step **saved-plan** pattern: `terraform plan -out=tfplan`, then
`terraform apply tfplan`. Apply executes the plan that was just computed and
shown — never a second re-plan. This is the mechanical TOCTOU fix and it changes
no operator behavior (the baseline layers still apply automatically on merge).

The org-root SCP layer (`management/scps`) additionally routes through a
human-review path, isolated into its own jobs so the blast radius is gated
without gating the rest:

- `plan-scps` plans the SCP layer, prints the plan, and uploads it as the
  `scps-plan` artifact (binary `tfplan` + `terraform show` text).
- `apply-scps` is bound to GitHub Environment `landing-zone-apply-scps`,
  downloads that artifact, and runs `terraform apply <plan file>`. If the
  environment has a required reviewer, the apply **waits for human approval of
  the exact uploaded plan**. If org state drifts during the approval wait, the
  saved plan is stale and `terraform apply` fails rather than applying — the
  TOCTOU window is closed, not merely narrowed.

**Arming (the conscious behavior change).** Referencing an environment that has
no protection rule does not pause anything — GitHub auto-creates it and runs.
To arm the gate, Bin does a one-time repo-settings action: **Settings →
Environments → New environment → `landing-zone-apply-scps` → Required reviewers
→ add himself → Save.** After arming, every merge that changes SCPs waits for
his click in the Actions tab before the org-root SCP plan applies. Until armed,
the SCP layer still applies automatically — but now via the reviewed saved plan,
so the mechanical #316 fix is in effect regardless.

The gate is scoped to SCPs deliberately: it is the only org-root-blast-radius
layer; gating all nine layers would put a click on every merge for negligible
security gain.

### D2 — Render the CI matrix from a single source of truth (#320)

`config/ci-layers.yaml` (committed) is the single ordered list of account-fabric
layers and the logical account each targets — no real account IDs (those stay in
`config/landing-zone.yaml`). `scripts/ci/render-ci-matrix.py` joins the manifest
with the config to emit the plan / apply matrices at pipeline time. The
hand-copied account IDs are gone from both workflow files; the plan matrix and
the apply matrices now derive from the same manifest and cannot drift from each
other. The renderer fails closed when a layer's account ID is empty (ADR-019
posture) rather than emitting a broken assume-role target.

`backend.tf` bucket names were **not** re-plumbed to `-backend-config=` in this
change — that touches `scripts/configure-backends.sh`, `cold-start-bootstrap.sh`,
and the local-dev init path (higher blast radius). Instead, drift is now
**caught**: policy check P4 (D3) asserts every `backend.tf` bucket equals
`<org>-terraform-state-<shared_id>` derived from the config. Full backend
derivation is deferred as a separate change (see Consequences → Open items).

The whole config still ships as one secret because Terraform's `yamldecode`
reads the entire file; shrinking it to per-field secrets is a larger redesign
(Open items).

### D3 — Policy-as-code gate: Python, not conftest/OPA or `terraform test` (#321)

`config-policy.yml` runs `terraform fmt -check`, `scripts/validate-config.py`,
and a new `scripts/ci/policy_test.py` on every PR and push. The suite encodes
the epic's guardrail invariants as fast, offline assertions (P1–P7): CI-role
permissions boundary (#313), the boundary deny-floor (#313), core SCP presence +
root attachment, backend↔config consistency (#320), manifest↔on-disk-layer
coverage (#320), config schema + one-primary-region, and the state-bucket
TLS-only statement.

**Tool choice.** The repo's config-test toolchain is already Python
(`scripts/validate-config.py`, wired into `.pre-commit-config.yaml`); the suite
extends that pattern. It adds no new binary, no Rego, no AWS credentials, and no
provider download, so it runs in well under a second and does not meaningfully
slow PR CI. `terraform test` would need provider init per layer (slow; 1.14.x
mock-provider plumbing across nine layers); conftest/OPA would add a binary and a
second policy language for the same assertions. If the invariant set outgrows
straightforward Python (e.g. needs plan-JSON evaluation), conftest/OPA over
`terraform show -json` is the documented upgrade path.

## Consequences

- Applied == reviewed for every layer; org-root SCPs get an opt-in human gate
  with stale-plan protection.
- One place (`config/ci-layers.yaml` + `config/landing-zone.yaml`) defines the
  pipeline's layer/account set; a new layer is added once, in the manifest.
- Guardrail regressions fail CI instead of merging.

### Open items (not addressed here — flagged, not silently dropped)

1. **Backend `-backend-config=` derivation.** `backend.tf` bucket names remain
   literal (synced by `configure-backends.sh`). Consistency is enforced by P4;
   full derivation is a separate change touching the bootstrap scripts.
2. **Opaque config secret.** The full config still ships as one CI secret
   because Terraform reads the whole file. Splitting sensitive fields
   (emails / SSO URL) from non-sensitive structure is a larger redesign.
3. **`tflint` / `terraform validate` in CI.** Present locally via pre-commit;
   not promoted to a required CI gate here to keep the new gate fast. Candidate
   follow-up if a validate-class regression ever slips through.
