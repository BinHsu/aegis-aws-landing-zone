# 032. External orchestration for multi-region EKS

## Status

Accepted. Supersedes [ADR-018](018-multi-region-eks-design.md) §3 (provider
pattern) and §4 (state structure). ADR-018 §1 (two region lists in config),
§2 (the four invariants), §5 (Route 53 failover), §6 (pilot-light DR mode),
and §7 (per-cluster ArgoCD) all survive unchanged.

## Context

ADR-018 chose the **slot pattern** for multi-region EKS: static provider
alias labels (`primary`, `slave_1`), one pre-declared "slot" per region up to
a fixed ceiling K=2, `count`-gated module invocations, and a hard
`terraform_data "assert_k2_max"` precondition replicated in all three workload
layers. It chose this because Terraform provider aliases cannot be generated
from a list (ADR-018 Alternatives D) — the slot pattern was the
Terraform-idiomatic workaround, and ADR-018 §3 documented a
`scripts/configure-providers.sh` template as the escape hatch if truly
dynamic N were ever needed.

The slot pattern was implemented and validated end-to-end (a length-2 apply +
teardown). It works. But the maintenance cost it carries is now visible:

- Every workload layer carries a `terraform_data "assert_k2_max"` precondition
  whose error message inlines a ~40-line unlock procedure.
- `providers.tf` carries `try(local.slave_regions[0], local.primary_region)`
  fallback gymnastics so an unoccupied slot can still instantiate a provider
  it will never use.
- Outputs carry parallel `primary` / `slave_1` map branches plus flat
  backward-compatibility shims.
- All multi-region resources for a layer share one state file, so a failed
  apply or a DR drill in one region plans against — and can corrupt — the
  other region's state.

The sibling repo **aegis-stateless** solved the identical Terraform
limitation with **external orchestration**, and its ADR-01 frames that as
*better than* dynamic provider aliases, not merely a workaround: each region
is applied independently with its own state, which gives blast-radius
isolation, parallel and canary applies, and granular per-region DR. Terraform
still has no `provider for_each` (reserved-but-unimplemented as of 1.16-alpha),
so the slot pattern's premise has not changed — migrating now is a deliberate
upgrade, not a reaction to a new language feature.

This ADR adopts external orchestration for `aegis-aws-landing-zone`, adapted
for two constraints aegis-stateless does not face:

1. **Multi-account.** ldz workload layers run in the `aegis-staging` account
   today and `aegis-prod` later. The orchestration loop is per-`(env, region)`,
   not per-region.
2. **A pre-existing config contract.** ADR-004 mandates a single YAML source
   of truth (`config/landing-zone.yaml`). Region topology stays there under
   the existing `eks.<env>.regions[]` key — ldz does **not** adopt
   aegis-stateless's separate `regions.auto.tfvars.json`.

### Industry framing

This is not a bespoke design — it has recognised names, worth stating so the
intent is legible to a reviewer:

- **Architecturally** it is a **deployment-stamp** (Azure Architecture Center's
  term) / **cell-based architecture** (AWS's term): each region is an
  independent, self-contained, identical *cell*; the system scales and
  isolates blast radius by replicating the cell rather than by growing a
  shared instance.
- **Mechanically** it is what HashiCorp later productised as **Terraform
  Stacks** — one configuration, N "deployments", typically one per region or
  account. ldz hand-rolls the equivalent with a `Makefile` / CI matrix loop
  (it is not on HCP Terraform); the same result is achievable with a
  Terragrunt `for_each` over regions. The defining property — one state file
  per region instance — is **per-region state isolation**.

The superseded ADR-018 "slot pattern" had no industry name; it was a
repo-local coinage for "multi-region inside a single root module, worked
around the static-provider-alias limitation". ADR-032 moves to the named,
conventional pattern.

## Decision

### 1. One `(env, region)` per Terraform apply

Each workload layer — `staging/network`, `staging/platform`,
`staging/workloads` — becomes a **single-region root module**. It declares
exactly one `provider "aws"`, with `region` driven from a `TF_VAR_region`
injected by the orchestrator. The k8s / helm / kubectl providers are likewise
single and non-aliased.

The cluster sub-modules (`modules/vpc`, `modules/eks-cluster`,
`modules/eks-workloads`) are kept, but they no longer declare
`configuration_aliases` — the root passes the default, unaliased providers.
The original reason the k8s-family providers had to live at the layer root
(Terraform rejects `module` + `count` + module-local providers) no longer
applies, because `count` is gone; the providers stay at the root anyway, as a
single declaration site, matching aegis-stateless's `regional/` layout.

### 2. Region topology stays in `config/landing-zone.yaml`

No new config file. The orchestrator (Makefile and CI) reads
`eks.<env>.regions[]` out of the YAML — using Python + PyYAML, consistent with
`scripts/configure-backends.sh` and `scripts/validate-config.py`, since ldz's
config is YAML, not the JSON that aegis-stateless filters with `jq`.

### 3. Region-scoped state keys

State keys become `<env>/<region>/<layer>/terraform.tfstate`. The three
workload layers move to **partial backend configuration** — `backend.tf`
declares only `terraform { backend "s3" { use_lockfile = true } }` with no
`bucket` / `key` / `region` literal — and the orchestrator supplies all three
via `terraform init -backend-config=` flags. This removes region literals from
`backend.tf` entirely (cleaner than the current templated form) and means
`scripts/configure-backends.sh` no longer templates these layers; baseline
layers keep their full-literal templated `backend.tf` unchanged.

### 4. The K-ceiling and its guards are deleted

`terraform_data "assert_k2_max"` is removed from all three layers. The
`maxItems: 2` constraint on `eks.<env>.regions` is removed from
`config/schema.json`. There is no ceiling: N regions is a pure config change.

The four cross-field invariants from ADR-018 §2 still hold, but they are now
validated **only** in `scripts/validate-config.py` (pre-commit). The
Terraform `check` blocks that duplicated them are removed — a single-region
apply has no cross-region list to check; the layer simply consumes its one
injected region.

### 5. Multi-region orchestration lives in the Makefile and CI matrix

A root `Makefile` and a data-driven GitHub Actions matrix loop over
`eks.<env>.regions[]`. The CI plan job gains a `setup` step that emits the
active region list as JSON; the workload plan/apply/teardown jobs become a
per-region matrix. The baseline-auto-apply / workload-manual-apply split
(cost guardrail) is preserved exactly — only the workload jobs become
per-region.

## Alternatives Considered

### A. Keep the slot pattern, raise K to 3

Rejected. It postpones the same problem one notch and the existence of a
40-line inlined "unlock procedure" is itself the evidence that the pattern is
a smell, not a fit.

### B. The `configure-providers.sh` template (ADR-018's own escape hatch)

Rejected. Generating `providers.tf` as a gitignored artifact costs
PR-diff reviewability, adds a CI prerequisite step, and — critically — still
keeps every region in one state file per layer. It removes the static-label
limitation but not the shared-state blast radius.

### C. Terragrunt

Rejected for now. Terragrunt would manage the per-`(env, region)` apply graph,
but the Makefile loop is sufficient at the current layer count and avoids
committing forkers to another tool. Revisit if the cross-account dependency
graph deepens — same reasoning as aegis-stateless ADR-01.

### D. Workspace per region

Rejected — already rejected in ADR-018 Alternatives C (workspace footguns,
region names leaking into state paths). Region-scoped state *keys* give the
per-region isolation without workspace semantics.

## Consequences

### Easier

- Adding region N is a one-line edit to `eks.<env>.regions[]` — no `.tf`
  change, no ADR amendment, no ceiling.
- Per-region blast radius: a failed apply, a DR drill, or a teardown in
  `eu-west-1` cannot touch `eu-central-1` state.
- `providers.tf` collapses from ~180 lines to ~40 per layer; `config.tf`
  sheds the `check` blocks and the `assert_k2_max` resource; outputs shed the
  map/shim duplication.
- Per-region state keys mean per-region lock files — the cross-region state
  lock races the current shared key papers over with `-lock-timeout` and
  `concurrency` groups simply cannot happen.

### Harder

- The orchestration moves out of Terraform into the Makefile + CI matrix —
  more workflow YAML, and a `setup` job that parses the config. A reader must
  look in two places (the layer's `.tf` and the orchestrator) to see the full
  multi-region picture.
- Cross-layer reads (`platform` reads `network`, `workloads` reads
  `platform`) now key on a region-scoped state path; the key format must be
  identical everywhere it appears (`backend.tf` partial config, the Makefile,
  every workflow). The format is fixed once here:
  `<env>/<region>/<layer>/terraform.tfstate`.
- `staging/observability` is primary-region-only (grafana-operator
  single-owner, ADR-022). It is **not** in the per-region matrix; it reads the
  *primary* region's `platform` state key specifically and runs once.

### Migration

The workload layers are torn down at the end of every session (cost
guardrail) — there is normally no live workload state. The implementing PR
verifies this (a read-only `terraform state list` against the three keys)
before cutover. If true, the refactor needs **no `terraform state mv`**: it
only changes how the next cold-apply behaves; the next apply writes directly
under the new region-scoped keys. If state is unexpectedly live, the operator
runs the existing teardown workflow first rather than attempting an in-place
backend-key migration of live EKS state.

### Portfolio implication

The repo now shows a *decision revisited with evidence*: the slot pattern was
built, validated, and then — once its maintenance cost was concrete rather
than hypothetical — replaced with the model the sibling repo proved out. The
ADR trail (018 → 032) is itself the artifact: it demonstrates judgment under
a real Terraform language limitation, not a single guess frozen in place.
