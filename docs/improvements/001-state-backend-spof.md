<!-- session-close-review: state bucket protection claims (versioning, KMS, no Object Lock, no replica) still match terraform/environments/shared/bootstrap -->
# 001. State backend cross-account + cross-region replica

## Current state

All Terraform state — every account, every layer — lives in a single S3 bucket in `aegis-shared`: `<org>-terraform-state-<shared-account-id>` in `eu-central-1`. Protection today:

| Mechanism | Present | Source |
|---|---|---|
| S3 versioning | ✅ | `terraform/environments/shared/bootstrap/main.tf:20` |
| KMS SSE with customer-managed CMK | ✅ | `terraform/environments/shared/bootstrap/kms-state.tf:19` |
| Non-current version expiration (30 days) | ✅ | `main.tf:40` |
| `prevent_destroy = true` on bucket | ✅ | `main.tf:15` |
| Public access block | ✅ | `main.tf:60` |
| Org-scoped bucket policy (`aws:PrincipalOrgID`) | ✅ | `main.tf:69` |
| Native S3 locking (`use_lockfile = true`) | ✅ | every layer's `backend.tf` |
| S3 Object Lock | ❌ | — |
| MFA Delete | ❌ | — |
| Cross-region replication | ❌ | — |
| Cross-account replication | ❌ | — |

## Gap / risk

| Failure mode | RPO today | RTO today | Explanation |
|---|---|---|---|
| Accidental object delete | ~0 | <5 min | ✅ versioning restores |
| Accidental `terraform destroy` on bucket | N/A | Blocked | ✅ `prevent_destroy` |
| Console/API bucket delete (emptied first) | ~0 | **Unbounded** | Must rebuild from git + re-import state across ~10 layers |
| Malicious actor with S3 write | ~0 | **Unbounded** | No Object Lock; delete is irreversible |
| `eu-central-1` region outage | Last write (hours) | **AWS-dependent** (historically hours-to-days) | No cross-region replica |
| `aegis-shared` compromise / closure | Last write | **90 days via AWS Support grace period** | No cross-account replica |

## Threat addressed

- **External attacker / insider malicious**: credential theft + malicious bucket delete.
- **AWS region-level outage**: regional service incident.
- **AWS account-level event**: accidental closure, SCP self-lock, credential takeover leading to deliberate destruction.

## RTO / RPO target

**Design target**: RPO=1h, RTO=1h for the CI / deployment path.

**Meets target by**:

- S3 native async replication to `aegis-logarchive` @ `eu-west-1`. Typical replication lag is well under 15 minutes — inside the 1h RPO budget. No Replication Time Control (RTC) needed.
- Pre-documented recovery runbook `docs/runbooks/005-state-bucket-recovery.md` (forward-referenced; listed as a dependency, not yet written).

**Lab limitation**: a single-operator lab without 24/7 on-call cannot meet RTO=1h in practice. Real-world recovery time during sleep is "next time the operator checks their phone" — 8–24 hours. The 1h target is for a productionized version, not lab reality. Documented honestly rather than hidden.

## Scope

**CI / deployment path only.** State bucket downtime does not affect:

- Running workloads (EKS control + data plane continue serving traffic).
- ArgoCD sync (it reads from GitHub, not from state).
- Any user-facing SLA.

State bucket downtime does affect:

- All `terraform plan` / `apply` operations.
- New workload provisioning.
- Incident response that requires an infrastructure change.

## SLO impact

| Path | Before | After |
|---|---|---|
| CI / deployment | ~2.5 nines (worst-case MTTR unbounded for malicious delete / region outage) | 3.5 nines (RTO=1h bounded) |

Workload data plane SLO unchanged — that's entry 008's concern, not this one.

## Proposed mitigation

Three layers, in priority order.

### Layer 1 — Cross-account, cross-region S3 Replication

- **Source**: `aegis-shared` / `<org>-terraform-state-<shared-id>` @ `eu-central-1`.
- **Destination**: `aegis-logarchive` / `<org>-terraform-state-replica-<logarchive-id>` @ `eu-west-1`.
- **Replication mode**: Native async (not RTC; RTC's 15-minute SLA is overkill for a 1h RPO and costs $0.015/GB extra).
- **Destination KMS**: separate CMK owned by `aegis-logarchive`. Source bucket re-encrypts objects on the replication boundary (default behavior for cross-KMS replication).
- **IAM**: source-side replication role in `aegis-shared` with cross-account write permission; destination bucket policy grants the role access.
- **GDPR**: `eu-west-1` (Ireland) is within the EU and satisfies [ADR-002](../decisions/002-region-and-availability-zone-strategy.md) region constraints.

### Layer 2 — S3 Object Lock on the replica bucket

- **Mode**: Governance (not Compliance). Compliance is irreversible for the retention period even with root credentials — misconfiguration under Compliance creates more risk than it prevents. Governance gives a legitimate break-glass path.
- **Retention**: 7 days — short enough to keep storage bounded, long enough to catch malicious delete and respond.

### Layer 3 — Documented recovery runbook

- `docs/runbooks/005-state-bucket-recovery.md` (not yet written; a separate improvement, listed in Prerequisites below).
- Steps: detect → validate replica integrity → re-point `backend.tf` from source to replica bucket → `terraform init -migrate-state` → resume operations.
- Each step has a time budget; total under 1 hour RTO.

## Alternatives Considered

### A. Periodic `terraform state pull` snapshots to a separate bucket

Rejected. Achievable RPO is bounded by cron cadence — at a 1-hour cadence, RPO is *up to* 1 hour with no headroom. S3 native replication achieves <15 min RPO with lower complexity and no additional scheduling.

### B. Dedicated 7th "state" account

Rejected. Smallest blast radius conceptually, but adds Control Tower baseline cost (~$5/month) and one more account to manage. For lab scale, logarchive as destination is architecturally coherent — its semantics are already "WORM cold-path audit data" — and cheaper.

### C. Replication Time Control (RTC)

Rejected. RTC guarantees 99.99% of objects replicated within 15 minutes for $0.015/GB extra. At a 1h target, native async replication has ample headroom. Save RTC for RPO≤15 min designs.

### D. S3 Object Lock — Compliance mode

Rejected. Compliance mode retention is irreversible even with root credentials. A misconfiguration under Compliance is unrecoverable within the retention period. Governance mode protects against the same threats (malicious delete, accidental delete) while allowing legitimate break-glass recovery.

### E. Do nothing (accept the SPOF as-is)

Documented as the current state. Acceptable for lab scale where data is bounded and reproducible; unacceptable for anything with real business data.

## Prerequisites

1. `aegis-logarchive` account exists and is Control Tower-provisioned. ✅ (Phase 1.)
2. Destination bucket must be created with Object Lock enabled at creation time. Object Lock **cannot be enabled retroactively** on an existing bucket.
3. Dedicated KMS CMK in `aegis-logarchive` for destination bucket encryption.
4. **Entry 002** (planned, *logarchive consolidation*) should ratify logarchive's WORM cold-path semantics and declare it as the canonical backup / audit destination before this entry consumes it.
5. `docs/runbooks/005-state-bucket-recovery.md` written and drilled at least once before this entry can be considered complete.

## Reversibility

| Component | Reversibility |
|---|---|
| S3 Replication rule | Fully reversible — remove rule any time |
| Destination bucket (Governance Object Lock) | Fully reversible; retention expires on existing objects |
| Destination bucket (Compliance mode) | **Irreversible within retention** — DO NOT USE |
| Destination KMS CMK | Reversible with 30-day deletion window |

**Net**: fully reversible if Governance mode is chosen; do not use Compliance.

## Cost estimate

At lab scale (state data ~50–200 MB including version history):

| Component | Monthly |
|---|---|
| Destination storage @ `eu-west-1` | ~$0.005 (200 MB × $0.023/GB) |
| Replication PUT requests | ~$0.01 |
| Cross-region data transfer | ~$0.02 |
| Destination KMS CMK | $1.00 (base + per-request) |
| Object Lock overhead | $0 (no separate charge) |
| **Total ongoing** | **~$1.05 / month** |

One-time implementation effort: ~4 engineering hours (Terraform module + bucket policy + replication role + integrity verification script).

## Operational burden

| Task | Cadence | Time |
|---|---|---|
| Replication lag / error alerts (automatic) | Continuous | 0 (no action unless alert fires) |
| Replica integrity diff (automated `aws s3 sync --dryrun`) | Monthly | 2 min to review output |
| Recovery drill (runbook dry-run) | Quarterly | 2 hours |
| **Total** | | **~2.5 hours / quarter** |

## Validation plan

1. **At implementation**: create a test object in the source bucket, confirm it appears in the replica bucket within 15 minutes.
2. **Monthly**: scheduled GitHub Action runs `aws s3 sync --dryrun` between source and replica; alerts if there is any diff beyond acceptable replication-lag noise.
3. **Quarterly**: execute the recovery runbook in full against a scratch workload layer. Measure wall-clock time from "detect" to "backend pointing at replica, plan clean".
4. **Success criterion**: three consecutive quarterly drills with RTO < 1h before the target is considered achievable.

## Portfolio angle

1. **Multi-account blast-radius thinking** — recognizing `aegis-shared` as a SPOF despite `prevent_destroy`, and selecting `aegis-logarchive` as the natural backup destination based on its WORM cold-path semantics rather than bolting on a new account.
2. **RPO/RTO-driven engineering discipline** — rejecting over-engineered RTC and Compliance-mode Object Lock; rejecting under-engineered snapshot-based approaches.
3. **EU data residency (GDPR)** baked directly into destination region selection.
4. **Operational realism** — explicit lab-vs-prod limitation (single-operator RTO ≠ target RTO) documented rather than papered over.

## Compliance / residency notes

- **GDPR**: destination `eu-west-1` is in-region. Compliant.
- **ISO 27001 Annex A.12.3.1 (Information backup)**: cross-account cross-region replication satisfies the "appropriate protection" clause.
- **ISO 27001 Annex A.17.1.2 (ICT continuity implementation)**: documented recovery runbook + quarterly drill satisfies the "verify at regular intervals" requirement.

## Lab status

**Not implemented.** Accepted because:

- State data is bounded and reproducible from git + AWS resources (worst-case rebuild from scratch is hours, not days — unlike real business data).
- No user traffic depends on the state bucket.
- Productionization cost (~$1/month) is small but operational burden (drill, monitoring) is not trivial for a single operator.

Scoped as a productionization fork target, not a lab implementation target.
