# 023. Detective Baseline — GuardDuty Org Auto-Enable + Security Hub FSBP, Lifecycle-Coupled

## Status

Accepted (2026-07-09). Epic #302, stages S2 (#304, PR #311), S3 (#305), S4 (#306), S5 (#307).

## Context

The epic-#302 review found the repo's #1 documentation-vs-reality gap: the README
asserted GuardDuty / Config / Security Hub were enabled, but no Terraform existed
for any of them, and the `security` + `logarchive` accounts had no Terraform
environment at all. S1 (#303) created those environments; S2 (PR #311) registered
the `security` account as the org delegated administrator for GuardDuty and
Security Hub (free — delegation only). This ADR records the decisions behind
S3/S4, the stages that actually turn the services on.

Two facts constrain the design:

1. **The Config aggregator is Control-Tower-managed.** The audit/security
   account already has a CT-provided org Config aggregator. Rebuilding it would
   duplicate CT-owned infrastructure and fight the CT baseline on every drift.
2. **The org is a near-zero-workload lab under a $30/month cap.** GuardDuty and
   Security Hub bill continuously once enabled, whether or not anything worth
   protecting exists.

### Non-contradiction with ADR-016 ("Why not GuardDuty")

[ADR-016](016-detective-controls.md) rejected GuardDuty — for a specific job:
deterministic alerting on failed OIDC assumptions, where an ML-tuned finding
pipeline is the wrong shape and EventBridge's literal pattern match is right.
That reasoning is untouched and still holds. This ADR adopts GuardDuty for the
job ADR-016 explicitly said it IS for: org-wide runtime threat detection across
member accounts ("GuardDuty earns its keep on the runtime side"). The two
detective layers are complementary — ADR-016's EventBridge rule watches one
deterministic control-plane event; this baseline watches everything else.

### CloudTrail: document-reliance (epic decision D1)

CloudTrail in this org is the CT-managed org trail (KMS-encrypted, archived to
`aegis-logarchive`). This repo does **not** own, re-create, or modify it — it
documents the reliance and builds on it: CloudTrail management events are
exactly the foundational data source GuardDuty analyzes. If CT's trail ever
goes away, GuardDuty's CloudTrail analysis (and much else) silently loses its
input — which is one reason the aggregator/trail layer stays CT-owned and
asserted rather than duplicated.

## Decision

| # | Decision | Where |
|---|----------|-------|
| 1 | GuardDuty org auto-enable `ALL` (existing + future members), foundational data sources only; every paid add-on (S3 / EKS audit / EBS malware / RDS login / Lambda network / Runtime Monitoring) explicitly pinned off at detector and org level | `terraform/environments/security/detective/guardduty.tf` |
| 2 | Security Hub LOCAL org configuration, `auto_enable_standards = "NONE"`, exactly one standards subscription (FSBP); finding aggregator homed in the primary region with the remaining governed region(s) linked | `securityhub.tf` |
| 3 | CT Config aggregator asserted read-only via a `check` block + `external` probe — never created or owned here | `ct-config-aggregator-check.tf` |
| 4 | **Lifecycle-coupled, not always-on** (decided by Bin on #305/#306, 2026-07-06): a single `detective_enabled` toggle destroys/creates every billable resource in the layer; member-detector residue is swept by `scripts/disable-member-detectors.sh` | `variables.tf`, `scripts/` |
| 5 | The layer is a separate Terraservice (`security/detective`), not mixed into the account baseline (epic D5), primary region only (epic D3) | `config/ci-layers.yaml` |

### Cost (eu-central-1, verified via the AWS Pricing API, 2026-07-09)

| Service | Pricing model | This org, near-zero workload |
|---------|--------------|------------------------------|
| GuardDuty foundational | $0.0000046 per CloudTrail management event analyzed ($4.60/M); VPC Flow/DNS $1.15/GB (first 500 GB tier) | 7 accounts × ~50–300k idle events/mo ≈ **$2–9/mo**; VPC/DNS ≈ $0 until VPCs exist |
| Security Hub CSPM | $0.0010 per security check (first 100k/account/region/mo) | FSBP in the security account only ≈ **$1–5/mo** |
| Config aggregator | CT-owned, pre-existing | $0 net new |
| **Total net new** | | **~$3–14/mo idle; plan ~$12–17/mo during an active validation window.** Both services give each account a one-time 30-day free trial. |

### Known gap — CI cannot yet exercise the aggregator check

The ADR-020 org-uniform CI permissions boundary's Allow ceiling covers
`guardduty:*` + `securityhub:*` (added with S2) but **not** the `config`
namespace. The aggregator check degrades to a plan **warning** in CI
(`found = "error"`, AccessDenied) and passes only under operator SSO
credentials. Fixing it is a deliberate 7-file, byte-identical boundary change
(all `*/bootstrap/ci-permissions-boundary.tf`) that touches the management
account's bootstrap — deferred out of the S3–S5 PR to avoid colliding with
parallel management-area workstreams. Follow-up: add `config:*` (or
`config:Describe*`) to the boundary ceiling in one uniform PR.

## Alternatives considered

- **Always-on detective services.** Rejected by Bin (2026-07-06, recorded on
  #305/#306): idle landing-zone accounts have nothing to detect; 24/7 enablement
  pays for protection on nothing. The Terraform code itself carries the
  portfolio fidelity; recurring cost accrues only during validation windows.
- **Security Hub CENTRAL configuration policies.** Would enroll existing member
  accounts and centrally push FSBP, but requires an ALL_REGIONS-style
  aggregation posture and adds per-account check volume (≈7× the Security Hub
  cost) — the wrong default for the frugal posture. Revisit if member-account
  coverage becomes a requirement (OQ-1).
- **Owning a Config aggregator in Terraform.** Rejected — the epic's key
  verified fact: CT already provides it. Import-and-own would make every CT
  landing-zone update a Terraform drift.
- **All GuardDuty features on.** Rejected — the paid add-ons protect resource
  types (S3 data events, EKS, RDS, Lambda, runtime agents) that do not exist in
  this org; enabling them is pure spend.

## Consequences

- `detective_enabled` defaults to **false** (decided by Bin, 2026-07-09): the
  layer lands and merges **dormant** — applying the default creates the layer
  scaffolding with zero billable resources. Turning the services on (recurring
  spend per the table above) is a deliberate follow-up: flip
  `detective_enabled = true` (one-line PR or tfvars override) and apply, timed
  together with the ephemeral-EKS validation run rather than as a side effect
  of landing this code. Detective-layer PRs stay **cost-gated** in spirit —
  the PR body carries the cost table — but the gate now protects the
  true-flip, not the initial merge.
- Disable path (future enabled→disabled transition): flip
  `detective_enabled = false` (one-line PR) → apply destroys the
  delegated-admin detector, org auto-enable, and Security Hub resources; then
  run `scripts/disable-member-detectors.sh --execute` under a
  management-account admin to delete the auto-created member detectors, which
  are outside Terraform state and would otherwise keep billing.
- `CKV2_AWS_3` (GuardDuty org-wide) left the Checkov skip list — the control is
  now codified, so Checkov asserts it instead of excusing it.
- The security account's CI roles gained `guardduty:*` / `securityhub:*`
  (apply) and read shapes + `config:Describe*` (plan) — inside the ADR-014
  namespace-scoping contract and (except `config`) inside the ADR-020 ceiling.

## Open questions

1. **OQ-1 — existing member accounts in Security Hub.** LOCAL org config with
   `auto_enable = true` covers only accounts that join AFTER the apply; the six
   existing members are not enrolled and FSBP runs in the security account
   only. Options when coverage matters: `aws_securityhub_member` resources, or
   CENTRAL configuration policies (cost ≈ 7×). Awaiting Bin's decision.
2. **OQ-2 — boundary `config` namespace.** See "Known gap" above; needed before
   the aggregator check can assert in CI.

## Related

- [ADR-016](016-detective-controls.md) — the deterministic OIDC-failure
  detective control; explicitly non-contradictory (see Context).
- [ADR-009](009-lifecycle-and-teardown-strategy.md) — the lifecycle posture the
  `detective_enabled` toggle extends to org-level services.
- [ADR-020](020-scp-enforced-ci-permissions-boundary.md) — the boundary ceiling
  that gates the aggregator check (OQ-2).
- [`docs/finops.md`](../finops.md) — the detective-baseline cost model.
- Epic #302; issues #303–#307; PR #311 (S2).
