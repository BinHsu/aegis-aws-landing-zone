<!-- session-close-review: current/target SLO tables and entry-list lab-status column still reflect reality -->
# Improvements — Known Gaps and Productionization Path

This directory documents **known gaps** between the current lab state and what a production-grade deployment of the AWS account fabric would require. It is an honest accounting, not a todo list — the lab deliberately stops short of production on cost and operational grounds. Each entry explains the gap, threat addressed, proposed mitigation, and cost/effort tradeoffs.

> **Scope note.** Per [ADR-033](../decisions/033-landing-zone-scope-correction-account-fabric.md) this repository owns the **account fabric** only. Improvement entries here are about the fabric's reliability — chiefly the Terraform state backend. Productionization gaps for the workload Platform tier (EKS multi-region, observability SLOs, DR drills) belong to the separate `aegis-platform` repository and are no longer tracked here.

## Why separate from ADRs

| `docs/decisions/` (ADRs) | `docs/improvements/` (this directory) |
|---|---|
| Captures **decisions made** | Captures **decisions deferred** or **gaps acknowledged** |
| "We chose X because Y" | "We would need X to achieve Y; we chose not to yet" |
| Persistent — rarely edited after ratification | Living — updated as gaps close or priorities shift |
| Mandatory for load-bearing architectural choices | Written when a gap is meaningful enough to reason about |

## Reliability posture snapshot

The account fabric has one reliability-critical asset: the Terraform state backend. It has no running data plane — there are no workloads in this repo to keep available.

### Today (lab baseline)

| Path | SLO estimate | Notes |
|---|---|---|
| CI / deployment path | ~2.5 nines (~99.8%) | State bucket SPOF in a single account + region; worst-case MTTR unbounded for a malicious delete or region outage |

### Design target (if fully productionized)

| Path | SLO target | Via |
|---|---|---|
| CI / deployment path | 3.5 nines with RPO=1h, RTO=1h | Cross-account + cross-region S3 replication ([001](001-state-backend-spof.md)) |

**Why 3.5 nines and not 4+**: RTO=1h × 1–2 incidents/year ≈ 3.5 nines ceiling. Achieving 4 nines requires RTO ≤ 10 min (automated failover, no human-in-the-loop), substantially higher cost and operational complexity. Documented as a conscious choice, not a limitation.

**Scope caveat**: CI path outages do not affect any running system — the account fabric provisions resources, it does not serve traffic. A state-backend outage blocks new `terraform apply` operations and incident-response infrastructure changes; it does not take anything down.

## Entry template

Each entry uses the fields below. Fields may be brief where non-trivial information isn't available, but should not be omitted outright:

- **Current state** — what exists today, factually.
- **Gap / risk** — what threat is unmitigated.
- **Threat addressed** — [Operator error | Insider malicious | External attacker | AWS outage | Compliance].
- **RTO / RPO target** — the design target and how the mitigation meets it; or an explicit lab limitation explaining why it can't.
- **Scope** — which SLO path this affects.
- **SLO impact** — before / after nines.
- **Proposed mitigation** — high-level approach; no Terraform code in this document.
- **Alternatives Considered** — two or more options rejected, each with a rejection reason.
- **Prerequisites** — dependencies on other entries, ADRs, or external readiness.
- **Reversibility** — [Fully | Partially | Irreversible, with a specific explanation].
- **Cost estimate** — monthly ongoing + one-time implementation.
- **Operational burden** — hours per month ongoing.
- **Validation plan** — how to verify the mitigation actually works.
- **Portfolio angle** — senior-engineering skill demonstrated (lab-specific).
- **Compliance / residency notes** — GDPR / ISO / region lock if applicable.
- **Lab status** — [Not implemented | Partially | Implemented].

See [`001-state-backend-spof.md`](001-state-backend-spof.md) for a fully worked example.

## Entries

| # | Title | Threat axis | Cost if productionized | Lab status |
|---|---|---|---|---|
| [001](001-state-backend-spof.md) | State backend cross-account + cross-region replica | AWS region outage, account-down | ~$1 / month | Not implemented |
| 002 | logarchive consolidation (backup + audit concentration) | Compliance audit, forensic readiness | ~$1 / month | Planned |
| 003 | Detection stack (EventBridge + GuardDuty + drift detection) | Operator error, insider malicious | ~$2–5 / month | Partial |
| 004 | Break-glass access (dedicated role, offline credentials) | Self-lockout, SSO compromise | ~$0 | Not implemented |
| 005 | Manual override policy (when console / CLI is allowed) | Operator error, audit gap | ~$0 (policy only) | Not implemented |
| 006 | Recovery drill cadence (state-backend restore) | Unvalidated RTO | ~$0 + 2h / quarter | Not implemented |

Entries with file links are written in full. Other numbers are tracked here as placeholder entries and will be expanded using the same template when prioritized.

## SPOF map

The region-down and account-down failure-mode inventory with cross-references to mitigation entries lives in [`spof-map.md`](spof-map.md). The map is the reference for "which entry addresses what" and is the structural entry point for the overall reliability story.

## Reading order

1. **Start here** — this README for posture context.
2. **[spof-map.md](spof-map.md)** — the failure-mode inventory by axis (region-down vs account-down).
3. **[001](001-state-backend-spof.md)** — full template exemplar; read to understand how each entry is analyzed.
4. Other entries as reference when considering a specific gap.

## Reference ADRs

Entries in this directory interact with or reference:

- [ADR-002 — Region and Availability Zone strategy](../decisions/002-region-and-availability-zone-strategy.md)
- [ADR-003 — Terraform backend bootstrap](../decisions/003-terraform-backend-bootstrap.md)
- [ADR-004 — Deployment configuration contract](../decisions/004-deployment-configuration-contract.md)
- [ADR-006 — Account taxonomy and OU structure](../decisions/006-account-taxonomy-and-ou-structure.md)
- [ADR-033 — Landing-zone descope to the account fabric](../decisions/033-landing-zone-scope-correction-account-fabric.md) — the scope boundary that defines what this directory tracks.
