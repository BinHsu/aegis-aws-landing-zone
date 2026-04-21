# 022. Observability backend: Grafana Cloud free tier

## Status

Accepted (2026-04-21). Supersedes [ADR-015](015-observability-tooling.md).

## Context

[ADR-015](015-observability-tooling.md) chose `kube-prometheus-stack` deployed in-cluster via ArgoCD as the observability backend. The core rationale was:

> "this project intentionally opts in to Prometheus operations as a portfolio artifact"

That rationale was reconsidered during Phase 4b review on 2026-04-21. Two observations drove the reversal:

1. Bin's CV already carries 3 years of production Prometheus operations on VM-based infrastructure (12 alert rules as Helm → ConfigMap → sidecar pipeline, see CLAUDE.md "Bin's Existing Experience"). A second demonstration of the same skill on Kubernetes repeats an existing signal rather than maturing the portfolio.

2. The stronger portfolio signal is "**observability as a replaceable platform capability**" — demonstrating that the service team's contract (metric emission, alert rules, dashboards) is backend-agnostic, and the platform team can swap the backend without breaking service teams. That abstraction skill is documented in [ADR-023](023-observability-responsibility-model.md); the current ADR chooses the backend that lets the abstraction be proven cheaply.

The lab's scale (1 operator, ≤ 2 clusters, <\$1/session observability budget) makes a managed SaaS free tier economically superior to self-hosting: \$0/session in steady state vs. ~\$0.25/session for in-cluster Prometheus + Grafana pods + EBS PVC.

### Why the reversal happened now

Phase 4b shipped kube-prometheus-stack in PR #67 (2026-04-15). The first cold-apply attempt (Session D, 2026-04-20) produced four incidents directly tied to the self-hosted stack: Incident 26 (Kyverno ServiceMonitor race), Incident 27 (node-exporter Fargate DaemonSet), Incident 28 (ServiceMonitor CRD bootstrap race), Incident 31 (Karpenter NodePool too small for Prometheus + ArgoCD controller). All are fixable (and were fixed). None added skill signals beyond "I debugged Prometheus Operator bootstrap races."

Each incident was cost the project paid to prove a skill Bin already has. The cumulative cost across incidents — compounded with the realization that the underlying rationale was CV-redundant — triggered this reversal.

## Decision

Four-layer stack. Cluster-side components managed via ArgoCD; external state in Grafana Cloud free tier; Terraform provisions machine identities after a single manual bootstrap token.

### Layer 1 — Agent: Grafana Alloy

- **Role**: scrape cluster and workload metrics; `remote_write` to Grafana Cloud Mimir; forward `PrometheusRule` CRDs to Mimir ruler for server-side evaluation.
- **Why Alloy over Prometheus agent mode**: Alloy's `prometheus.operator.*` components natively discover `ServiceMonitor` / `PodMonitor` / `PrometheusRule` CRDs without a Prometheus Operator controller or Prometheus server. Alloy is Grafana Labs' strategic agent; agent mode is a transitional feature on the Prometheus side.
- **Deployment**: DaemonSet (per-node scraping) + Deployment (cluster-wide CRD discovery and ruler forwarding). Runs in both `cluster_primary` and `cluster_slave_1` slots.

### Layer 2 — CRD definitions: `prometheus-operator-crds`

- **Role**: install only the Prometheus Operator CRDs (`ServiceMonitor`, `PodMonitor`, `PrometheusRule`, etc.). No Operator controller, no Prometheus server.
- **Why separate from Alloy**: the CRDs are the portable contract surface ([ADR-023](023-observability-responsibility-model.md)). They exist independently of whether anyone is scraping them. Alloy consumes CRDs; CRDs do not depend on Alloy.
- **Chart**: `prometheus-community/prometheus-operator-crds` via ArgoCD Application.

### Layer 3 — Alerting and dashboards IaC: `grafana-operator`

- **Role**: reconcile Kubernetes CRDs against Grafana Cloud via the Grafana API.
- **CRDs reconciled**:
  - `Grafana` — target stack (URL + service account token credential)
  - `GrafanaDashboard` — platform + service dashboards
  - `GrafanaContactPoint` — Slack / PagerDuty destinations (secret reference to K8s Secret)
  - `GrafanaNotificationPolicy` — routing tree root
  - `GrafanaNotificationPolicyRoute` — leaf routes (one per workload team)
  - `GrafanaMuteTiming` — maintenance windows
- **Deployment**: `cluster_primary` only (rationale in § Multi-region below).
- **Chart**: `grafana/grafana-operator` via ArgoCD Application.
- **Maturity note**: grafana-operator reached v5 in 2023. We accept the maturity risk in exchange for the CRD-first alerting IaC story; see § Known limitations.

### Layer 4 — Backend: Grafana Cloud free tier

- **Region**: `prod-eu-west-3` (Frankfurt / eu-central). Region is locked at stack creation; chosen to match AWS primary region and EU data residency posture.
- **Free tier quota**: 10k active metric series, 50 GB logs / 14-day retention, 50 GB traces / 14-day retention, 3 users. Sufficient for single-operator lab.
- **Overage behavior**: throttle ingestion (default). No credit card attached, forcing throttle-on-overage rather than auto-upgrade-on-overage. A 10k active series budget with cardinality guardrails (§ Cardinality and PII guardrails) keeps us below the ceiling.
- **Data residency**: metrics, logs, traces stored in AWS EU regions; Grafana Labs uses AWS as sub-processor. DPA applied via ToS on free tier; commercial tier upgrades would require explicit DPA signature.

### Rule evaluation location: server-side (Mimir ruler)

Alloy pushes `PrometheusRule` CRDs to Grafana Cloud Mimir ruler via its management API. Rules are evaluated inside Grafana Cloud, not on the cluster.

**Consequence**: if the cluster control plane is unreachable, alerts defined on metrics that were being pushed (e.g., `up`, `kube_node_status_condition`) continue to fire from server-side evaluation until samples stop arriving. This is a more resilient posture than cluster-local evaluation.

## Auth and secret chain

### Human auth — Google OAuth

Grafana Cloud free tier does not support SAML (SAML is gated on Pro tier). Human authentication is Google OAuth for as long as this project sits on free tier.

- Operator (Bin) logs in at `https://aegis-staging.grafana.net` using Google OAuth.
- A break-glass admin user is provisioned at onboarding time, separate from any service account, ensuring the human can recover when machine tokens are broken.
- SAML via AWS IAM Identity Center becomes available on Grafana Cloud Pro; native one-click AWS IdC only on AMG. Both are rung-transition triggers ([ADR-021](021-observability-scaling-path.md) amendment).

### Machine auth — single bootstrap, Terraform-provisioned rest

Grafana Cloud does not federate AWS OIDC identities as of 2026. At least one human-generated token is unavoidable — the "first secret" problem universal to SaaS integration. We compress the manual surface to a single bootstrap token.

**Step 1 (manual, one-time)**: Bin creates a Cloud Access Policy in the Grafana Cloud Portal with the minimum scopes needed to provision downstream identities:

```
Scopes: accesspolicies:read, accesspolicies:write,
        stacks:read,
        stack-service-accounts:read, stack-service-accounts:write,
        stack-api-keys:write
Expires: 30 days
```

30-day expiry is deliberately shorter than the 90-day downstream token rotation cadence — the bootstrap token is the root of trust and rotates more frequently than what it provisions.

Bootstrap token stored in SSM Parameter Store at `/aegis/<env>/grafana-cloud/bootstrap-token`.

**Step 2 (Terraform)**: the `grafana/grafana` provider authenticates with the bootstrap token and provisions:

- `aegis-<env>-alloy` Cloud Access Policy scoped to `metrics:write, logs:write` for this stack → its token stored at `/aegis/<env>/grafana-cloud/alloy-token`
- `grafana-operator` Grafana Service Account with Admin role inside the stack → its token stored at `/aegis/<env>/grafana-cloud/grafana-operator-token`

**Step 3 (runtime)**: External Secrets Operator (IRSA-authenticated to AWS) reads the two downstream parameters from SSM PS and creates the corresponding Kubernetes Secrets. Alloy and grafana-operator mount these Secrets for API authentication.

### Secret storage — SSM Parameter Store SecureString

Chosen over AWS Secrets Manager. Comparison on axes that matter here:

| Axis | SSM PS SecureString (chosen) | Secrets Manager |
|---|---|---|
| Cost (3 secrets) | \$0/month | ~\$1.20/month |
| KMS encryption | Via CMK alias `aegis-<env>-secrets` | Via CMK |
| IRSA-based read | Supported | Supported |
| Auto-rotation via Lambda | Not supported | Supported but inapplicable (Grafana Cloud lacks rotation API) |
| Cross-region replication | Manual via Terraform `for_each` | Native one-flag |
| External Secrets Operator backend | `ParameterStore` provider | `SecretsManager` provider |

None of Secrets Manager's differentiating features apply to this use case. The existing `karpenter-iam.tf` uses SSM PS for AMI lookup, so the repo pattern is consistent. Future conditions under which Secrets Manager becomes the right choice are enumerated in § Future switch triggers.

### Secret path convention

All Grafana Cloud secrets live under `/aegis/<env>/grafana-cloud/`:

```
/aegis/staging/grafana-cloud/bootstrap-token
/aegis/staging/grafana-cloud/alloy-token
/aegis/staging/grafana-cloud/grafana-operator-token
/aegis/staging/grafana-cloud/team-webhooks-slack-platform
/aegis/staging/grafana-cloud/team-webhooks-slack-aegis
```

Per-team webhook keys (`team-webhooks-*`) enable IAM policies that restrict which IRSA role can read which team's webhook, as future hardening.

### IAM policy for External Secrets Operator

```hcl
statement {
  actions   = ["ssm:GetParameter", "ssm:GetParameters"]
  resources = ["arn:aws:ssm:${region}:${account_id}:parameter/aegis/${env}/grafana-cloud/*"]
}
statement {
  actions   = ["kms:Decrypt"]
  resources = [aws_kms_key.secrets.arn]
  condition {
    test     = "StringEquals"
    variable = "kms:ViaService"
    values   = ["ssm.${region}.amazonaws.com"]
  }
}
```

Resource ARN patterning keeps External Secrets' blast radius bounded: it can read the grafana-cloud namespace under this environment only, not AWS credentials or other secret families. The KMS condition ensures decryption attempts must flow through SSM (not a direct kms:Decrypt on the key from another service).

## Multi-region (K=2 slot pattern per ADR-018)

- **Both slots** run: Alloy, `prometheus-operator-crds`, External Secrets Operator, platform-level `PrometheusRule` / `GrafanaDashboard` / `GrafanaContactPoint` CRDs.
- **Only `cluster_primary`** runs: `grafana-operator`.

### Rationale for primary-only grafana-operator

grafana-operator reconciles against a single Grafana Cloud stack. If both clusters ran grafana-operator, they would race on identical `GrafanaContactPoint` / `GrafanaNotificationPolicy` resources and never converge. The Grafana Cloud control-plane is per-stack, not per-cluster; the reconciler must likewise be per-stack-plus-single-owner.

`cluster_slave_1` is a data-plane participant (ships metrics and alerts via Alloy → Mimir); it is not a control-plane participant for Grafana Cloud configuration.

### External label convention

Alloy on each cluster adds an external label at `remote_write` time:

```
cluster=primary     # on cluster_primary
cluster=slave_1     # on cluster_slave_1
```

This label is mandatory. Without it, metrics from both clusters collide in Mimir and dashboards cannot distinguish cluster of origin. Platform-owned dashboards use `cluster` as a dashboard variable; service-owned dashboards must do the same when multi-region is active.

### Primary-loss failure mode

If `cluster_primary` is lost for more than 24 hours and not recoverable:

- `cluster_slave_1`'s Alloy keeps pushing metrics — data plane survives
- `grafana-operator` is gone — no config changes to dashboards, contact points, or routing until primary is restored or the operator is redeployed to slave_1
- Acceptable for the lab; a real DR posture would consider this a rung-2 migration trigger ([ADR-021](021-observability-scaling-path.md))

## Cardinality and PII guardrails

### Cardinality budget

The 10k active series cap is the operational constraint. Budget allocation:

| Pool | Allocation | Scope |
|---|---|---|
| Platform baseline | 5,000 | kube-state-metrics, node-exporter, Karpenter, Kyverno, cert-manager, ArgoCD, grafana-operator, Alloy self-metrics |
| Service metrics | 4,000 | aegis-core gateway + engine + future workload teams |
| Ad-hoc / buffer | 1,000 | Debugging sessions, temporary instrumentation |

Active series usage is monitored by self-scraping Grafana Cloud's usage endpoint; a `PrometheusRule` alerts at 8,000 series sustained for 10 minutes (80% of cap).

### Alloy relabel rules (platform-owned)

```
prometheus.relabel "drop_pii_and_low_value" {
  forward_to = [...]

  // PII guardrail — drops user-identifying labels before remote_write
  rule {
    action = "labeldrop"
    regex  = "user_id|email|ip_addr|client_ip|user_agent|session_id"
  }

  // Low-value families dropped to reclaim cardinality space
  rule {
    action = "labeldrop"
    regex  = "go_.*|process_.*|promhttp_.*"
  }
}
```

The PII drops are a platform guardrail against accidental instrumentation emitting user-identifying labels from workload code — the platform does not trust workloads to self-police this. The low-value drops (Go runtime, process stats, promhttp) reclaim cardinality space for business-relevant metrics; if a specific debug need arises, the relabel rule can be temporarily narrowed in a feature-flagged config.

## Teardown

Grafana Cloud resources (dashboards, contact points, notification policies) are created by grafana-operator reconciling Kubernetes CRDs. They do **not** auto-teardown when the cluster is destroyed unless the CRDs are deleted first and finalizers complete.

The teardown workflow must execute in order:

1. `kubectl delete grafanadashboards grafanacontactpoints grafananotificationpolicies grafananotificationpolicyroutes --all -A`
2. Wait 2 minutes for finalizers to complete
3. Verify Grafana Cloud portal shows resources removed
4. `terraform-teardown-workload.yml` proceeds

This pre-step is added to `terraform-teardown-workload.yml` as a new first stage.

**Emergency nuke path**: if grafana-operator is broken and finalizers hang, operators can delete the Grafana Cloud stack entirely from the Portal (this destroys all resources including historical metrics), or run `scripts/emergency/nuke-grafana-cloud.sh` which uses `mimirtool` and Grafana API DELETE calls.

## Alternatives Considered

### Keep ADR-015 (self-hosted kube-prometheus-stack in-cluster)

Rejected. The portfolio signal "I can operate Prometheus" is already on Bin's CV from VM-based production work. A second demonstration on Kubernetes is repetition. The four incidents (26, 27, 28, 31) from Session D cold-apply were cost paid to prove a skill that was already proven; continuing to pay that cost is inconsistent with the portfolio's actual gaps.

### Mixed IaC — CRD rules plus Terraform-managed routing

Keep `PrometheusRule` CRDs for alert rules, but use the Grafana Terraform provider directly for contact points and notification policies rather than grafana-operator.

Rejected. Two toolchains (kubectl + Terraform) against the same Grafana Cloud API creates drift opportunities. Pure CRD reconciliation keeps a single source of truth and a single reconcile loop. The routing IaC via grafana-operator uses the same Grafana provider's API targets under the hood — we accept the operator maturity cost in exchange for architectural uniformity.

### AMG + AMP directly

Upgrade to AWS Managed Grafana + AWS Managed Service for Prometheus today.

Rejected at current scale. AMG pricing (\$9/editor, \$5/viewer per month) with one active user is \$108/year for a demo workspace. AMP usage pricing starts at the first sample. Both are defensible at rung-3 scale but are over-provisioned for a single-operator lab. [ADR-021](021-observability-scaling-path.md) rung-3 triggers describe when this swap becomes appropriate.

### Grafana Cloud Pro (not free)

Upgrade to Pro for SAML, PrivateLink, and higher quotas.

Rejected. Pro pricing (~\$19/active user/month + metered ingestion) is ~\$228/year purely to access SAML for one operator. If human SSO requirements emerge (operator headcount growth, audit obligations), Pro becomes a defensible interim step before AMG.

### Prometheus agent mode (not Alloy)

Run `prometheus --enable-feature=agent` to scrape and `remote_write` to Grafana Cloud, skipping Alloy.

Rejected. Prometheus agent mode works but is a transitional feature. Alloy's `prometheus.operator.*` CRD-discovery components are native to the ServiceMonitor / PodMonitor / PrometheusRule ecosystem without a Prometheus Operator controller. For the portfolio narrative, Alloy demonstrates knowledge of Grafana Labs' strategic agent direction rather than a legacy transitional path.

## Consequences

### What changes in the repository

- **[ADR-015](015-observability-tooling.md) is superseded**. Content is preserved as historical record; Status field flags the supersession.
- **[ADR-021](021-observability-scaling-path.md) is amended**: rung 1's instantiation changes from kube-prometheus-stack to Grafana Cloud free tier + Alloy + grafana-operator. The ladder structure (three rungs) and rung 2 / rung 3 definitions are unchanged. A new rung-3 transition trigger is added: "need SAML SSO for human access."
- **[ADR-016](016-admission-control.md), [ADR-018](018-multi-region-eks-design.md), [ADR-020](020-fis-dr-drill.md)** receive minor amendments updating references to ADR-015 and noting the new mechanism where relevant (Alloy + grafana-operator replacing in-cluster Prometheus + Grafana).
- **`docs/improvements/009-grafana-sso-integration.md`** is marked obsoleted — Grafana Cloud has native Google OAuth; SAML is the Pro-tier upgrade path documented in ADR-021 rung transitions.

### New dependencies

| Component | Layer | Purpose |
|---|---|---|
| Grafana Alloy | platform (helm_release via ArgoCD) | scrape + remote_write + rule forward |
| `prometheus-operator-crds` chart | platform (helm_release via ArgoCD) | CRD definitions only |
| External Secrets Operator | platform (helm_release via ArgoCD) | SSM PS → K8s Secret |
| grafana-operator | workloads (ArgoCD Application, primary only) | reconcile Grafana* CRDs |
| `grafana/grafana` Terraform provider | workloads TF layer | bootstrap → downstream token provisioning |

### What aegis-core (cross-repo) needs to change

The platform-surface contract widens from ADR-015's Discovery Contract (3 CRDs) to [ADR-023](023-observability-responsibility-model.md)'s responsibility model (5 CRDs). aegis-core #46 (Observability surface contract) is updated from `cross-repo/fyi` to `cross-repo/blocking` because the new CRDs (`GrafanaDashboard`, `GrafanaContactPoint`, `GrafanaNotificationPolicyRoute`) are scope aegis-core has not previously committed to.

aegis-core had not yet shipped any observability manifests (per #46 "What aegis-core needs to decide — non-blocking"), so this is net-new scope, not a breaking change to existing manifests.

### Migration story (to AMP + AMG when rung 3 triggers)

See [ADR-023](023-observability-responsibility-model.md) § Migration safety for the full diff. Short form: aegis-core CRD surface is backend-agnostic; migration changes Alloy's `remote_write` destination + auth, adds IRSA for SigV4, and swaps the `Grafana` CRD target. aegis-core sees zero changes.

## Known limitations

1. **SAML not in free tier**. Human SSO is Google OAuth or email/password. SAML via AWS IAM Identity Center becomes available on Pro tier; native AWS IdC is only on AMG.
2. **10k active series is tight**. Combined platform + service cardinality must stay below 10k. Alloy relabel rules mitigate; the 8k alert gives early warning.
3. **Active series is a 30-minute sliding window**. Dashboards show time-series gaps when a source stops emitting for longer than the window — expected behavior on teardown-heavy lab usage.
4. **Orphan Grafana Cloud resources on bad teardown**. Skipping the pre-teardown CRD deletion leaves dashboards and routing on Grafana Cloud; next cold-apply re-reconciles, but if local YAML has changed between sessions, the old version may persist alongside the new.
5. **grafana-operator v5 maturity**. Released 2023. Some edge cases (contact point secret references, CRD garbage collection) have had recent fixes. If operator stability becomes a blocker, the fallback is the mixed IaC path described in § Alternatives Considered.
6. **Bootstrap token single trust anchor**. A leaked bootstrap token can provision arbitrary downstream tokens. Mitigations: 30-day expiry shorter than downstream 90-day cycle, scope-minimized, IAM condition restricting read to Terraform GitHub Actions OIDC role.
7. **Grafana Cloud outage is an alerting blind spot**. Alloy's remote_write queue buffers ~500k samples (~1 hour of typical volume); beyond that, samples are dropped. Acceptable for lab. Production posture would require a local Prometheus buffer or a secondary destination — documented as a rung-2 trigger.
8. **Account bound to personal email**. The Grafana Cloud account is registered to `pcpunkhades@gmail.com`. Lab-appropriate; production would require corporate SSO at the Grafana org level and multiple org admins.

## Future switch triggers

When to revisit this decision and potentially supersede ADR-022:

- **RDS / Aurora introduction** → revisit SSM PS vs Secrets Manager; SM's native RDS rotation is compelling for database credentials.
- **Cross-account secret sharing** → Secrets Manager resource policies; SSM PS requires cross-account IAM delegation.
- **Active series persistently > 8,000 with drops exhausted** → Grafana Cloud Pro (pay for headroom) or AMP migration (rung-3 trigger).
- **SAML SSO requirement** → Grafana Cloud Pro (SAML via AWS IAM Identity Center) or AMG (native AWS IdC); the choice depends on seat count.
- **Seat count > 10 active users** → AMG's per-seat pricing becomes competitive with or cheaper than Grafana Cloud Pro at this scale ([ADR-021](021-observability-scaling-path.md) rung-3 economics).
- **Data residency hardening** → if EU stack still does not satisfy auditors, AMP in a customer-owned AWS account closes the gap.

## Security posture

- **Least-scope tokens**: bootstrap holds provisioning scopes only; Alloy holds `metrics:write, logs:write` only; grafana-operator holds stack Admin only. Cross-token scope tests (see runbook) verify no token has more scope than needed.
- **SSM PS CMK per environment**: key alias `aegis-<env>-secrets`; key policy allows decryption only by the External Secrets IRSA role and Terraform's GitHub Actions OIDC role.
- **Path-based IAM scoping**: External Secrets IAM policy restricts reads to `/aegis/<env>/grafana-cloud/*` — cannot read other secret families, cannot read across environments.
- **Bootstrap token 30-day expiry**: shorter than downstream 90-day tokens, forcing regular human review of the trust anchor.

## Related

- [ADR-015](015-observability-tooling.md) (superseded) — original kube-prometheus-stack decision
- [ADR-021](021-observability-scaling-path.md) (amended) — scaling ladder; rung 1 redefined in terms of this ADR
- [ADR-023](023-observability-responsibility-model.md) — observability responsibility model; the contract preserved across backend swaps
- `docs/runbooks/006-grafana-cloud-onboarding.md` — operator onboarding and token rotation procedure
- aegis-core #46 — cross-repo coordination; contract surface widened per this ADR and ADR-023
