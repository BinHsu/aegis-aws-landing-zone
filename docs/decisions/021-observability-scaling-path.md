# 021. Observability scaling path

## Status
Accepted (amended 2026-04-21: rung 1 redefined per ADR-022; § "Not on the ladder" section split; SAML trigger added to rung 3)

## Context

[ADR-015](015-observability-tooling.md) chose **`kube-prometheus-stack` deployed in-cluster** as the observability stack for this project. The Phase 4c operator-install placement (Kyverno / cert-manager → `platform/`; kube-prometheus-stack / Argo Rollouts → `workloads/`, per [ADR-016](016-admission-control.md) amendment + [ADR-015](015-observability-tooling.md)) cemented the in-cluster pattern.

This ADR does **not** change that decision for the lab. What it does is document the scaling path: at what org / cluster / traffic scale does "in-cluster per-cluster" stop being defensible, and what replaces it?

Without this ADR, the repo gives a reviewer the right answer for the wrong reason — "in-cluster is fine" reads as a universal claim when it's actually a scale-conditional one. Interview-grade answer: the model is a three-tier scaling ladder, and we explicitly sit on rung 1.

### Lab framing (why this project stays on rung 1)

This lab is **demo-oriented**:
- Single operator
- At most ~2 clusters (length-2 multi-region slot pattern, both single-purpose)
- Observability cost budget < \$1/session
- Grafana viewer count: 1 (Bin) with occasional interviewer screen-share
- ISO 27001 Annex A framing is educational, not audit-prep

At this scale, **any** observability stack more elaborate than in-cluster kube-prometheus-stack would be over-engineering for over-engineering's sake — the additional components exist to solve problems the lab does not have (cross-cluster dashboards, long-term retention, high-cardinality alerting fleet, per-team tenant isolation).

## Decision

Three-tier scaling ladder. Each rung has an explicit trigger for moving up; none of the rungs are "always use the next one." The lab sits on **rung 1**. The ladder is the design document, not an instruction to climb.

### Rung 1 — Single-stack observability (where the lab lives)

- **Stack**: Grafana Cloud free tier + Grafana Alloy + grafana-operator + prometheus-operator-crds
- **Retention**: 14 days in Grafana Cloud
- **Grafana**: Google OAuth via Grafana Cloud workspace
- **Alertmanager**: Grafana Cloud managed (via grafana-operator CRDs)
- **Operational cost**: \$0/session in steady state (free tier; no EBS PVC, no compute pods)
- **Skill-portability**: reduced somewhat from in-cluster ~100% — Alloy is Grafana Labs-specific; PrometheusRule / ServiceMonitor CRDs remain portable

**When this is the right answer**: single cluster, single operator or tiny team (1–3 engineers), no SAML SSO requirement, no compliance SLA on >14-day metric retention, teardown cadence per-session, cost budget < \$10/month.

**When this stops being the right answer** (triggers to move up):
- Cluster count ≥ 3 AND operators want unified view
- Metric retention > 14 days for debugging / compliance
- \> 10 viewers routinely looking at dashboards
- Multi-region with cross-region latency comparisons (already covered today)
- **Need SAML SSO for human access — free tier supports only Google/GitHub OAuth**

> Historical instantiation: this rung was originally defined in terms of kube-prometheus-stack in-cluster ([ADR-015](015-observability-tooling.md)); redefined 2026-04-21 per [ADR-022](022-observability-backend-grafana-cloud.md). See ADR-022 §Context for the reversal rationale.

### Rung 2 — Central self-hosted (shared observability account)

- **Stack**: **Thanos** or **Grafana Mimir** in a dedicated observability account (extends this repo's `shared/` account pattern — new layer `shared/observability/` or a new account `aegis-observability/`)
- **Workload-cluster side**: `kube-prometheus-stack` stays in each cluster, but configured with `remote_write` to the central store (TLS + IAM-authenticated)
- **Long-term storage**: S3 bucket in the observability account
- **Grafana**: single self-hosted instance with SSO (AWS Identity Center SAML — same IdP ADR-009 uses), pulling from the central store
- **Retention**: infinite (or policy-driven), S3-backed
- **Operational cost**: ~\$200–500/month + 0.3–0.5 FTE operator time
- **Skill-portability**: 100% — Thanos/Mimir are CNCF, vendor-neutral

**When this is the right answer**:
- Multi-cluster (≥3) organization
- ≥ 100 engineers, ≥ 3 platform engineers dedicated enough to own Thanos operations
- Cross-cluster dashboards + queries are a daily need (SRE / oncall drives this)
- Retention requirements beyond 7 days (compliance, week-over-week regression analysis)
- Org values vendor-neutrality and can afford the operational tax

**When this stops being the right answer**:
- Platform team is < 3 people and Thanos oncall becomes a top source of pages
- AWS lock-in becomes acceptable in exchange for ops reduction
- Metric ingestion crosses into the AMP pricing sweet spot (see rung 3)

### Rung 3 — AWS Managed (AMG + AMP)

- **Stack**: **AWS Managed Grafana** + **AWS Managed Prometheus**
- **Workload-cluster side**: `kube-prometheus-stack` stays (or is replaced by bare `prometheus-operator` without Grafana); metrics remote_write to AMP
- **Grafana**: AMG workspace, AWS Identity Center integration native, per-seat pricing (~\$9 Editor / \$5 Viewer / month)
- **Retention**: 150 days in AMP default
- **Operational cost**: ~\$100–300/month for a 20–30 viewer team + AMP per-GB ingestion
- **Skill-portability**: 50% — PromQL still applies; Grafana dashboards export as JSON; but AMG-specific configuration (workspace IAM, private access, service role) is AWS-only

**When this is the right answer**:
- **100-person startup with 5 platform engineers** (the canonical fit)
- Team is already AWS-native and OK with deeper lock-in
- Zero tolerance for observability operator headaches — AWS operates Grafana/Prometheus for you
- Grafana Cloud is rejected because data must stay in AWS VPC (compliance)
- Seat count is bounded (< 100 users) so per-seat pricing is tractable
- Need SAML SSO (free tier is Google OAuth only; Pro tier SAML is manual setup; AMG SAML via AWS IAM Identity Center is one-click native)

**When this stops being the right answer** (triggers to move back to rung 2):
- Seat count crosses ~100 users — linear seat cost starts beating Thanos's fixed-cost curve
- Metric ingestion crosses ~\$1k/month on AMP — at that volume, self-hosted Mimir becomes cheaper
- Custom recording rules, multi-tenant dashboard permissions, or non-AWS data sources become daily needs — AMG's customization ceiling gets hit

### Not a single rung, but related SaaS paths

#### Managed SaaS free tier (Grafana Cloud free tier)

This IS now rung 1. Previously rejected in the original version of this ADR based on ADR-015's "opt in to Prometheus operations" framing; rationale reconsidered in ADR-022.

#### Managed SaaS paid tier (Grafana Cloud Pro)

NOT a standalone ladder rung, but lives as an EDGE CASE between rung 1 and rung 3: when SAML SSO becomes necessary (operator headcount growth, audit requirements) but seat count is still <10 so AMG's per-seat economics doesn't yet win, Pro is the defensible interim.

#### Full vendor SaaS (Datadog, New Relic, etc.)

STILL rejected. Reasons unchanged: per-host / per-metric pricing volatility, data-leaves-VPC compliance concern, skill portability reduced further than AMG (vendor-specific APM paradigms don't transfer to CNCF stacks).

> **Original framing (superseded inside this section):**
>
> > Already rejected in [ADR-015](015-observability-tooling.md) §Alternatives for this lab; re-rejected here as a production path for the same reasons (SaaS vendor lock, per-metric pricing volatility, data-leaves-VPC compliance concern, skill portability reduced further than AMG).
> >
> > If an org explicitly values "we never self-operate observability" over every other axis, Datadog is the right answer — but for an org that chose AWS as its primary cloud and values AWS-native controls, AMG + AMP already covers the SaaS-desire better.

## Alternatives Considered

### "AMG-first, collapse to a single rung"

Argument: just use AMG + AMP for staging AND prod. No rung 1 at all; lab trains on the thing that will be used at scale.

Rejected. AMG-first for a demo-oriented lab:
1. Costs \$15–20/month in per-seat fees for 1–2 demo viewers — \~\$180–240/year on what should be a \~\$30/year lab
2. Requires workspace provisioning + Identity Center SAML app + workspace IAM — hours of setup for a demo that runs 10 minutes
3. Skill signal reversed: "I can operate Prometheus" degrades to "I can point-and-click AMG"
4. AWS lock-in at a stage where the project explicitly signals vendor-neutral skill ([ADR-008](008-landing-zone-tooling-control-tower-hybrid.md) Control-Tower-hybrid framing has the same cost/benefit structure)

### "Rung 2 directly — Thanos-in-shared-account from day one"

Argument: the `shared/` account already exists (IPAM, state); add `shared/observability/` now so the scaling path is already built by the time scale arrives.

Rejected for the lab. Thanos operational tax is ≈ 0.3 FTE even when traffic is negligible — the control plane (Sidecar, Store, Querier, Compactor) has to be run, monitored, and upgraded regardless of ingestion volume. For one operator, that's a disproportionate ongoing cost for a demo-tier observability need.

The ladder acknowledges this as the *next* rung; climbing it for a lab is YAGNI.

### "In-cluster with Thanos sidecar, S3 remote_write"

Argument: extend rung 1 with just the Thanos sidecar for long-term storage in S3 — gets retention without the full rung-2 stack.

Rejected (for now) as additional complexity beyond the lab's retention needs. 24-hour retention is sufficient for a 4-hour session; extending it would be a Phase 5 concern if lab iteration cycles lengthen.

Could be revisited as "rung 1.5" if the lab retention window ever needs to grow without triggering full rung 2.

## Consequences

### The lab is explicitly on rung 1, with known migration paths

The project documents:
- The observability pattern it uses (rung 1)
- The scale triggers that would move it to rung 2 or rung 3
- The scale signal that would move it from rung 3 back to rung 2 (seat count / ingestion cost crossovers)

This is a maturity signal — the project is not claiming its observability posture is production-grade; it is claiming the posture is **appropriate for its scale** and the operator understands where the rungs are.

### Interview-grade answers

When a reviewer asks "how does your observability scale?", the answer is:

> "The lab is rung 1 — Grafana Cloud free tier + Alloy + grafana-operator, with PrometheusRule / ServiceMonitor CRDs staying portable. I stay on rung 1 until one of five triggers fires: cluster count ≥ 3 with unified-view need, retention beyond 14 days, > 10 viewers, cross-region latency analysis beyond what's already there, or a SAML SSO requirement that free-tier Google/GitHub OAuth can't serve. Rung 2 is central self-hosted Thanos/Mimir in a dedicated account — it's the default for scale-ups with a platform team that can run 0.3 FTE worth of Thanos operations. Rung 3 is AMG + AMP — it's the default for 100-person startups with 5 platform engineers, where seat count is bounded, SAML-via-IAM-Identity-Center is one-click native, and the ops tax on Thanos isn't worth it. I'd pick rung 3 over rung 2 specifically for that kind of shape because 5 PE already have too much to do for Thanos compactor pages."

The answer flexes to the interviewer's context:
- Enterprise SRE interviewer → emphasize rung 2 operational detail (Compactor downsampling, Store gateway caching)
- Startup CTO interviewer → emphasize rung 3 seat-economics and the ops-bandwidth framing
- Both → mention the trigger criteria, don't pretend any tier is universally right

### What this does NOT cover

- **APM / tracing** (Datadog, Tempo, Jaeger) — this ADR is metrics-only. Tracing has a different tier structure.
- **Log aggregation** — CloudWatch Logs / Loki / Elasticsearch sit on a parallel but independent ladder.
- **Synthetic monitoring** — CloudWatch Synthetics / Checkly — another parallel ladder.

Each of these may warrant its own scaling-path ADR when the project touches them.

## Related

- [ADR-015](015-observability-tooling.md) — the rung-1 decision itself
- [ADR-008](008-landing-zone-tooling-control-tower-hybrid.md) — vendor-neutral-vs-managed framing; same pattern here
- [ADR-018](018-multi-region-eks-design.md) — slot pattern; rung 2 would extend this to cross-region federated metrics
- `docs/improvements/001-state-backend-spof.md` — shared account is already the home for "needs-to-be-outside-any-single-workload-account"; rung 2 would land in the same account family
