<!-- session-close-review: dollar figures match the current account-fabric layer set; budget caps match the management-account config -->

# FinOps — Cost Model

This repository owns the **AWS account fabric** — Organizations, OUs, SCPs, IAM Identity Center, account bootstrap and vending, the Terraform state backend, the GitHub OIDC provider, the centralized security/audit baseline, and the org-wide IPAM. Resources that bill while idle — EKS, NAT Gateways, ALBs — are platform concerns and out of scope here.

The consequence for cost: almost every layer here is a cheap, persistent baseline layer, and the cost model is "what does the always-on fabric cost". The one exception since epic #302 is the **detective baseline** (`security/detective` — GuardDuty org-wide + Security Hub FSBP): it is deliberately **lifecycle-coupled**, not always-on — enabled for validation windows, disabled between them (see "Detective baseline" below and ADR-023).

Region for all figures: `eu-central-1` (Frankfurt). Prices are on-demand list and rounded; they move — treat them as order-of-magnitude, not invoices.

## Cost philosophy

Two lifecycles. The baseline layers — `management/*`, `shared/*`, and every `*/bootstrap` — are cheap, persistent, auto-applied on merge to main. They hold organization structure, SCPs, IAM/OIDC, IPAM, and the Terraform state bucket; they cost a few dollars per month and are *never* destroyed. The **detective layer** (`security/detective`) is the exception: it carries a `detective_enabled` toggle and rides the platform bring-up/teardown lifecycle, because idle landing-zone accounts have nothing to detect (decided by Bin on #305/#306; ADR-023).

The discipline in one sentence: **the account fabric runs forever at ~$5/month; the detective baseline adds ~$12–17/month only while a validation window is active.**

## Per-layer cost breakdown

| Layer | Main cost-incurring resources | Billing shape | ~Cost while idle |
|-------|-------------------------------|---------------|------------------|
| `management/bootstrap` | Organizations, CloudTrail org trail → S3 | Storage + events | ~$0 |
| `management/scps` | Service Control Policies | Free | $0 |
| `shared/bootstrap` | KMS keys, S3 | Per-key + storage | <$2/mo |
| `shared/ipam` | IPAM (Advanced tier) | Per-active-IP + per-pool | ~$0 idle (see below) |
| `shared/aft` | AFT pipeline (committed, not deployed — ADR-011) | Free while not applied | $0 |
| `staging/bootstrap` | S3 state bucket (native locking), KMS, GitHub OIDC role | Storage + per-key | <$2/mo |
| `prod/bootstrap` | Same shape as `staging/bootstrap` | Storage + per-key | <$2/mo |
| `deployment/bootstrap` / `security/bootstrap` / `logarchive/bootstrap` | IAM roles, OIDC provider, account alias | Free | $0 |
| `security/detective` | GuardDuty org-wide + Security Hub FSBP (lifecycle-coupled) | Per-event + per-check (see below) | $0 toggled off; ~$12–17/mo enabled |

## The always-on baseline (~$5/month)

The persistent cost of the account fabric is dominated by the Control Tower baseline that begins billing the moment the landing zone is enrolled:

| Component | Billing shape | ~Monthly |
|-----------|---------------|----------|
| AWS Config recorder (per-account, all governed accounts) | Per configuration item recorded | ~$2–3 |
| CloudTrail org trail | First trail free; S3 storage + events | ~$0.50 |
| S3 log storage (CloudTrail + Config archive in `aegis-logarchive`) | Storage + lifecycle | ~$0.50 |
| KMS customer-managed keys (state bucket, log encryption) | $1/key/mo + per-request | ~$2 |

Total order of magnitude: **~$5/month**, persistent. None of it is destroyed — it is the cost of having a governed multi-account organization at all. GuardDuty and Security Hub are deliberately NOT in this table — they belong to the lifecycle-coupled detective baseline below, not the always-on floor.

## Detective baseline (lifecycle-coupled) — ~$12–17/month while enabled

Epic #302 codified GuardDuty (org-wide auto-enable, foundational data sources
only) and Security Hub (FSBP standard only) in
`terraform/environments/security/detective/`. Decided by Bin (2026-07-06,
recorded on #305/#306): these are **not always-on** — the `detective_enabled`
toggle enables them for platform validation windows and destroys them at
teardown (member-detector cleanup:
`terraform/environments/security/detective/scripts/disable-member-detectors.sh`).
See ADR-023.

Pricing (`eu-central-1`, verified against the AWS Pricing API 2026-07-09):

| Component | Billing shape | This org, ~Monthly while enabled |
|-----------|---------------|----------------------------------|
| GuardDuty foundational — CloudTrail management events, all 7 accounts | $0.0000046 per event analyzed ($4.60/M) | ~$2–9 at idle-to-light API traffic |
| GuardDuty foundational — VPC Flow Logs + DNS logs | $1.15/GB (first 500 GB tier) | ~$0 until platform VPCs exist |
| Security Hub — FSBP checks (security account only; see ADR-023 OQ-1) | $0.0010 per check, first 100k/account/region/mo | ~$1–5 |
| Security Hub — finding ingestion | Check-generated findings free; first 10k other events free | ~$0 |
| GuardDuty paid add-ons (S3/EKS/Malware/RDS/Lambda/Runtime) | Explicitly pinned OFF in Terraform | $0 |

Net new while enabled: **~$3–14/month at today's idle traffic; budget
~$12–17/month for an active validation window** (more API activity = more
CloudTrail events analyzed). Both services grant each account a one-time
30-day free trial, so the first validation window is largely free. Toggled
off: $0.

## IPAM — the only usage-priced item

AWS IPAM Advanced tier is the one component here whose bill scales with usage rather than being flat:

- **Idle cost** is effectively $0 — pricing is per *active IP address* managed by IPAM and per IPAM-monitored resource. With no downstream VPCs allocated, IPAM monitors nothing and bills nothing meaningful.
- When a downstream consumer allocates VPC CIDRs from the RAM-shared pools, IPAM begins billing per active IP. At lab scale this is cents per month; it is the consumer's cost, not the fabric's.

This is the only line item where "what does it cost" depends on what is deployed elsewhere — and even then it is negligible.

## Budget caps

Managed by Terraform (ADR-019) in the `aegis-management` account:

- **Daily**: $10 — a tripwire; the account fabric should never approach this.
- **Monthly**: $30 — the hard ceiling for the lab.

Each member account additionally carries a $10 monthly budget: staging and
shared in their own bootstrap layers, logarchive via a LinkedAccount-filtered
budget in the management layer (the logarchive account has no Terraform
environment of its own).

The expected envelope for this repo is the ~$5/month always-on baseline, rising to ~$17–22/month total while a detective-enabled validation window is active — still under the $30 monthly cap, but no longer far under it. The $10 daily / $30 monthly caps are kept as tripwires; if the daily alert fires for the account fabric alone, something is genuinely wrong (a runaway Config recorder, a misconfigured trail, or a detective window someone forgot to close) and warrants investigation.

## Cost-saving levers

| Lever | Effect |
|-------|--------|
| S3 native state locking (`use_lockfile = true`) | No DynamoDB lock table — one fewer billed resource |
| Gateway VPC endpoints (S3/DynamoDB) over interface endpoints | Gateway endpoints are free; not applicable until a VPC exists, but the convention is set |
| Single org CloudTrail trail | First trail per account is free; avoid redundant trails |
| Config recorder scoped to relevant resource types | Per-configuration-item pricing rewards not recording noise |
| AFT committed but not deployed (ADR-011) | The scaling path stays fresh via CI validation without incurring the ~$10–15/mo AFT pipeline cost |
| Detective baseline lifecycle-coupled (`detective_enabled`, ADR-023) | GuardDuty + Security Hub bill only during validation windows, not 24/7; paid GuardDuty add-ons pinned off; FSBP is the only Security Hub standard |
