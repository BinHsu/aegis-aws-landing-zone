<!-- session-close-review: dollar figures match the current layer resource set; budget caps match the management-account config -->

# FinOps — Cost Model

This is a lab landing zone. It is *designed* to be torn down. The cost model
is therefore not "what does it cost to run" but "what does it cost while a
session is open, and what leaks if a teardown is skipped".

Region for all figures: `eu-central-1` (Frankfurt). Prices are on-demand list
and rounded; they move — treat them as order-of-magnitude, not invoices.

## Cost philosophy

Two tiers, two lifecycles:

- **Baseline layers** — `management/*`, `shared/*`, `staging/bootstrap`,
  `staging/secrets-persistent`, `staging/auth`. Cheap, persistent, auto-applied
  on merge. They hold organisation structure, SCPs, CloudTrail, IPAM, the
  Terraform state bucket, and SaaS-credential SSM parameters. They cost cents
  per month and are *never* torn down.
- **Workload layers** — `staging/network`, `staging/platform`,
  `staging/workloads`, `staging/observability`, `staging/edge`, `staging/fis`.
  Expensive, ephemeral, **manually** applied (never auto-applied — see
  `CLAUDE.md` Cost Guardrails). They hold the NAT Gateway, the EKS control
  plane, EC2 nodes, and the ALB. They are torn down at the end of every
  session.

The discipline in one sentence: **baseline runs forever and costs nothing;
workload costs real money and must not survive the session.**

## Per-layer cost breakdown

| Layer | Main cost-incurring resources | Billing shape | ~Cost while idle |
|-------|-------------------------------|---------------|------------------|
| `management/bootstrap` | Organizations, CloudTrail org trail → S3 | Storage + events | ~$0 |
| `management/scps` | Service Control Policies | Free | $0 |
| `shared/bootstrap` | KMS keys, S3 | Per-key + storage | <$2/mo |
| `shared/ipam` | IPAM (free tier) | Free | $0 |
| `staging/bootstrap` | S3 state bucket (native locking), KMS | Storage + per-key | <$2/mo |
| `staging/secrets-persistent` | SSM Parameter Store (Standard SecureString) | Free | $0 |
| `staging/auth` | Cognito User Pool | Free < 50k MAU | $0 |
| `staging/network` | **NAT Gateway**, interface VPC endpoints | Hourly + data | **~$32/mo per NAT + ~$7/mo per endpoint** |
| `staging/platform` | **EKS control plane**, Karpenter EC2 nodes, EBS, **ALB** | Hourly | **~$73/mo per cluster + nodes + ~$16/mo ALB** |
| `staging/observability` | grafana-operator (in-cluster), Alloy | No extra AWS cost | $0 (Grafana Cloud free tier) |
| `staging/edge` | CloudFront, ACM, Route53 hosted zone | Request-based + $0.50/mo zone | <$1/mo idle |
| `staging/fis` | FIS experiment templates | Per-action, only when run | ~$0 |

### The expensive four

These bill *while idle* — they are the reason a skipped teardown is a cost
incident:

| Resource | Hourly | If left 24h | If left a weekend (~60h) |
|----------|--------|-------------|--------------------------|
| EKS control plane | $0.10 | $2.40 | $6.00 |
| NAT Gateway | ~$0.052 | ~$1.25 | ~$3.10 |
| ALB | ~$0.025 + LCU | ~$0.70 | ~$1.75 |
| EC2 nodes (2× t3.medium on-demand) | ~$0.096 | ~$2.30 | ~$5.75 |

A single forgotten cluster over a weekend is ~$17 — more than half the monthly
budget cap. That is the whole reason for the teardown rule.

## Multi-region multiplier

Each additional active EKS region is, to first order, a **full second copy** of
the `network` + `platform` + `workloads` cost: another EKS control plane (+$73/mo
equivalent), another NAT Gateway, another ALB, another node set. A two-region
session roughly **doubles** the expensive-four hourly rate to ~$0.55/hr.

Pilot-light DR (ADR-018 / ADR-032) keeps the DR region's capacity *pre-warmed
but minimal* rather than a hot mirror — the multiplier is real but the node
count in the DR region is held low.

## Budget caps

Configured in the `aegis-management` account:

- **Daily**: $10 — alerts if a session runs long or a teardown is skipped.
- **Monthly**: $30 — the hard ceiling for the lab.

Expected envelope: Phase 0–2 work stays under $5; a Phase 3+ session that
brings up EKS runs ~$5–10 and is torn down the same day.

If the daily alert fires, the first hypothesis is *a workload layer left
running* — check for a live EKS cluster, NAT Gateway, or ALB before anything
else.

## Teardown cadence

- **Never** leave EKS, NAT Gateway, or ALB running overnight.
- End every session that applied workload layers with a teardown. Preferred
  path (portfolio-visible audit trail):
  ```
  gh workflow run terraform-teardown-workload.yml -f env=<env>
  gh run watch
  ```
  Local fallback: `./scripts/teardown/soft-teardown-workload.sh <env>`.
- `staging/network` destroy takes 20–30 min (IPAM + gateway endpoints +
  multi-region) — budget that into session close, do not assume it is instant.

## Cost-saving levers

| Lever | Effect |
|-------|--------|
| Spot capacity via Karpenter | ~70% off node compute |
| S3 native state locking (`use_lockfile = true`) | No DynamoDB lock table — one fewer billed resource |
| Single NAT Gateway per VPC (not per-AZ) | Avoids 2–3× NAT cost; accepted AZ-failure trade-off for a lab |
| Pilot-light DR, not hot standby | DR region holds minimal pre-warmed capacity, not a full mirror |
| Gateway VPC endpoints (S3/DynamoDB) over interface endpoints where possible | Gateway endpoints are free; interface endpoints bill hourly |
| Manual workload apply (never auto) | A merge never silently starts an EKS cluster |
| Teardown at session end | The single largest lever — idle workload layers are the dominant cost |
