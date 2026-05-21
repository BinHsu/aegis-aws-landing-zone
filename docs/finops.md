<!-- session-close-review: dollar figures match the current account-fabric layer set; budget caps match the management-account config -->

# FinOps — Cost Model

This repository owns the **AWS account fabric** — Organizations, OUs, SCPs, IAM Identity Center, account bootstrap and vending, the Terraform state backend, the GitHub OIDC provider, the centralized security/audit baseline, and the org-wide IPAM. Resources that bill while idle — EKS, NAT Gateways, ALBs — are platform concerns and out of scope here.

The consequence for cost: this repo has **no per-session cost-incurring layers**. Every layer here is a cheap, persistent baseline layer. The cost model is "what does the always-on fabric cost", not "what leaks if a destroy is skipped" — there is nothing to destroy.

Region for all figures: `eu-central-1` (Frankfurt). Prices are on-demand list and rounded; they move — treat them as order-of-magnitude, not invoices.

## Cost philosophy

One tier, one lifecycle. Every layer — `management/*`, `shared/*`, `staging/bootstrap`, `prod/bootstrap` — is a baseline layer: cheap, persistent, auto-applied on merge to main. They hold organization structure, SCPs, CloudTrail, AWS Config, GuardDuty, IPAM, and the Terraform state bucket. They cost a few dollars per month and are *never* destroyed.

The discipline in one sentence: **the account fabric runs forever and costs ~$5/month; there is no ephemeral cost in this repo.**

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

## The always-on baseline (~$5/month)

The persistent cost of the account fabric is dominated by the Control Tower baseline that begins billing the moment the landing zone is enrolled:

| Component | Billing shape | ~Monthly |
|-----------|---------------|----------|
| AWS Config recorder (per-account, all governed accounts) | Per configuration item recorded | ~$2–3 |
| CloudTrail org trail | First trail free; S3 storage + events | ~$0.50 |
| S3 log storage (CloudTrail + Config archive in `aegis-logarchive`) | Storage + lifecycle | ~$0.50 |
| KMS customer-managed keys (state bucket, log encryption) | $1/key/mo + per-request | ~$2 |
| GuardDuty (org-wide) | Per GB of analyzed events / logs | ~$0–1 at fabric-only traffic |

Total order of magnitude: **~$5/month**, persistent. None of it is destroyed — it is the cost of having a governed multi-account organization at all.

## IPAM — the only usage-priced item

AWS IPAM Advanced tier is the one component here whose bill scales with usage rather than being flat:

- **Idle cost** is effectively $0 — pricing is per *active IP address* managed by IPAM and per IPAM-monitored resource. With no downstream VPCs allocated, IPAM monitors nothing and bills nothing meaningful.
- When a downstream consumer allocates VPC CIDRs from the RAM-shared pools, IPAM begins billing per active IP. At lab scale this is cents per month; it is the consumer's cost, not the fabric's.

This is the only line item where "what does it cost" depends on what is deployed elsewhere — and even then it is negligible.

## Budget caps

Configured in the `aegis-management` account:

- **Daily**: $10 — a tripwire; the account fabric should never approach this.
- **Monthly**: $30 — the hard ceiling for the lab.

The expected envelope for this repo is comfortably under the ~$5/month baseline. The $10 daily / $30 monthly caps are kept as generous tripwires; if the daily alert fires for the account fabric alone, something is genuinely wrong (a runaway Config recorder, a misconfigured trail) and warrants investigation.

## Cost-saving levers

| Lever | Effect |
|-------|--------|
| S3 native state locking (`use_lockfile = true`) | No DynamoDB lock table — one fewer billed resource |
| Gateway VPC endpoints (S3/DynamoDB) over interface endpoints | Gateway endpoints are free; not applicable until a VPC exists, but the convention is set |
| Single org CloudTrail trail | First trail per account is free; avoid redundant trails |
| Config recorder scoped to relevant resource types | Per-configuration-item pricing rewards not recording noise |
| AFT committed but not deployed (ADR-011) | The scaling path stays fresh via CI validation without incurring the ~$10–15/mo AFT pipeline cost |
