<!-- session-close-review: current/target SLO tables and entry-list lab-status column still reflect reality -->
# Improvements — Known Gaps and Productionization Path

This directory documents **known gaps** between the current lab state and what a production-grade deployment would require. It is an honest accounting, not a todo list — the lab deliberately stops short of production on cost and operational grounds. Each entry explains the gap, threat addressed, proposed mitigation, and cost/effort tradeoffs.

## Why separate from ADRs

| `docs/decisions/` (ADRs) | `docs/improvements/` (this directory) |
|---|---|
| Captures **decisions made** | Captures **decisions deferred** or **gaps acknowledged** |
| "We chose X because Y" | "We would need X to achieve Y; we chose not to yet" |
| Persistent — rarely edited after ratification | Living — updated as gaps close or priorities shift |
| Mandatory for load-bearing architectural choices | Written when a gap is meaningful enough to reason about |

## Reliability posture snapshot

### Today (lab baseline — no DR running)

| Path | SLO estimate | Notes |
|---|---|---|
| Workload data plane | ~3 nines (99.9%) | Single-region multi-AZ, `eu-central-1` |
| CI / deployment path | ~2.5 nines (~99.8%) | State bucket SPOF in single account + region; worst-case MTTR unbounded |
| Observability SLI | Phase 4 shipped (Prometheus + Grafana) | No empirical SLO baseline yet — see entry 007 |
| Multi-region extent | **IPAM + config schema only** | Workload clusters single-region by default |

### Design target (if fully productionized)

| Path | SLO target | Via |
|---|---|---|
| Workload data plane | 3.5 nines (99.95%) | Active-passive pilot light per [ADR-018](../decisions/018-multi-region-eks-design.md) |
| CI / deployment path | 3.5 nines with RPO=1h, RTO=1h | Cross-account + cross-region S3 replication ([001](001-state-backend-spof.md)) |

**Why 3.5 nines and not 4+**: RTO=1h × 1–2 incidents/year ≈ 3.5 nines ceiling. Achieving 4 nines requires RTO ≤ 10 min (automated failover, no human-in-the-loop), substantially higher cost and operational complexity. Documented as a conscious choice, not a limitation.

**Scope caveat**: CI path outages do NOT affect running workloads — they only block new deployments. The two SLOs are calibrated separately.

## Entry template

Each entry uses the fields below. Fields may be brief where non-trivial information isn't available, but should not be omitted outright:

- **Current state** — what exists today, factually.
- **Gap / risk** — what threat is unmitigated.
- **Threat addressed** — [Operator error | Insider malicious | External attacker | AWS outage | Compliance].
- **RTO / RPO target** — the design target and how the mitigation meets it; or an explicit lab limitation explaining why it can't.
- **Scope** — which SLO path this affects (CI, workload, both).
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
| 003 | Detection stack (EventBridge + GuardDuty + drift detection) | Operator error, insider malicious | ~$2–5 / month | Phase 4 partial |
| 004 | Break-glass access (dedicated role, offline credentials) | Self-lockout, SSO compromise | ~$0 | Not implemented |
| 005 | Manual override policy (when console / CLI is allowed) | Operator error, audit gap | ~$0 (policy only) | Not implemented |
| 006 | Recovery drill cadence | Unvalidated RTO | ~$0 + 2h / quarter | Not implemented |
| 007 | SLI / SLO empirical baseline | No ground truth for SLO claims | included in Phase 4 | Phase 4 partial (SLIs collected, no SLO targets yet) |
| [008](008-workload-multi-region.md) | Workload multi-region DR (active-passive pilot light) | AWS region outage | ~$2 / session (Mode A) or ~$1 / month (Mode B persistent) | Partially implemented — schema ready, modules pending Session B |

Entries with file links are written in full. Other numbers are tracked here as placeholder entries and will be expanded using the same template when prioritized.

## SPOF map

The region-down and account-down failure-mode inventory with cross-references to mitigation entries lives in [`spof-map.md`](spof-map.md). The map is the reference for "which entry addresses what" and is the structural entry point for the overall reliability story.

## Reading order

1. **Start here** — this README for posture context.
2. **[spof-map.md](spof-map.md)** — the failure-mode inventory by axis (region-down vs account-down).
3. **[001](001-state-backend-spof.md)** — full template exemplar; read to understand how each entry is analyzed.
4. **[008](008-workload-multi-region.md)** — multi-region workload scope boundary; references [ADR-018](../decisions/018-multi-region-eks-design.md) for the architectural spec.
5. Other entries as reference when considering a specific gap.

## Reference ADRs

Entries in this directory interact with or reference:

- [ADR-002 — Region and Availability Zone strategy](../decisions/002-region-and-availability-zone-strategy.md)
- [ADR-003 — Terraform backend bootstrap](../decisions/003-terraform-backend-bootstrap.md)
- [ADR-004 — Deployment configuration contract](../decisions/004-deployment-configuration-contract.md)
- [ADR-006 — Account taxonomy and OU structure](../decisions/006-account-taxonomy-and-ou-structure.md)
- [ADR-013 — EKS architecture (single-region baseline)](../decisions/013-eks-architecture.md)
- [ADR-018 — Multi-region EKS design](../decisions/018-multi-region-eks-design.md) — the architectural spec that entry 008 implements.
