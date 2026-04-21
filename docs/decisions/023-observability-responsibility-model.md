# 023. Observability responsibility model

## Status

Accepted (2026-04-21). Refines the Discovery contract originally written in [ADR-015](015-observability-tooling.md) § Consequences.

## Context

[ADR-015](015-observability-tooling.md) added a "Discovery contract" paragraph (2026-04-20) formalizing the split between platform-provided machinery and workload-declared intent. The contract was narrow: platform provides Prometheus Operator; workload teams declare `ServiceMonitor`, `PrometheusRule`, and `PodMonitor` CRDs. Everything else — dashboards, contact points, notification routing — lived implicitly inside `kube-prometheus-stack`'s Grafana configuration, neither assigned nor discussed.

When the backend decision was revisited in [ADR-022](022-observability-backend-grafana-cloud.md), two gaps surfaced:

1. **Unassigned surfaces**. Dashboards, contact points, notification routing, and mute timings had never been explicitly owned by either platform or service teams. They were latent in the Helm chart and implicitly platform-owned by accident of packaging, not by design.
2. **Backend-coupled vocabulary**. The original contract was defined in `kube-prometheus-stack` terms — `release=` label selectors, Helm chart scope. The underlying *responsibility principle* is backend-independent and deserves an ADR of its own, so it survives across backend swaps.

The principle this ADR crystallizes: **the observability contract between platform and service teams is the artifact worth preserving across backend changes**. [ADR-022](022-observability-backend-grafana-cloud.md) chose the current backend; this ADR defines the contract that stays stable when [ADR-021](021-observability-scaling-path.md)'s rung-transition triggers eventually force that backend to swap.

## Decision

Observability is split into two concern domains. Each resource type in the stack belongs to exactly one domain.

### Platform domain (landing-zone)

Observability stack health + Kubernetes substrate + platform services (Karpenter, Kyverno, cert-manager, ArgoCD, grafana-operator itself).

**Characteristics**:

- Invisible to service teams — platform alerts fire on platform pagers, not service pagers.
- Composable across workloads — one platform rule covers every namespace.
- Cross-cutting — the same failure mode (e.g., node NotReady) affects every service identically.

### Service domain (aegis-core or any workload team)

Specific workload service behavior. Business-logic aware.

**Characteristics**:

- Business-logic aware — `gateway_request_duration_seconds{route="/v1/chat"} p99` needs domain knowledge of what the route does.
- Owned by the team writing service code — rule maintenance lives in the same repo as the code emitting the metric.
- Teachable to that team's on-call rotation — runbook for a service alert is written by the team whose service it is.

### Ownership table

| Resource | Platform | Service team | Notes |
|---|:-:|:-:|---|
| `Grafana` CRD (target stack) | ✓ | | One per cluster; points at Grafana Cloud stack URL + token |
| External Secrets Operator (install + IRSA) | ✓ | | Platform bootstrap; not workload-scoped |
| `SecretStore` / `ClusterSecretStore` (SSM PS provider) | ✓ | | Single source of truth per environment |
| `team-webhooks` K8s Secret (multi-key) | ✓ | | One key per team (`slack-aegis`, `slack-platform`); service teams reference by key |
| `PrometheusRule` — platform concerns | ✓ | | NodeNotReady, DeprecatedKubernetesAPI, KubePodCrashLooping, CertificateExpiringSoon, GrafanaOperatorReconcileFailed (meta-observability) |
| `PrometheusRule` — service SLOs | | ✓ | GatewayP99LatencyHigh, EngineErrorRateHigh, SLOBurnRate\* |
| `ServiceMonitor` / `PodMonitor` | | ✓ | Service team declares what to scrape; Alloy discovers via CRD selectors |
| `GrafanaDashboard` — platform | ✓ | | Kubernetes overview, Karpenter, Kyverno, cert-manager, ArgoCD, grafana-operator |
| `GrafanaDashboard` — service | | ✓ | aegis RED metrics, per-route latency, business KPIs |
| `GrafanaContactPoint` | | ✓ | Service team declares destination; references platform-provided Secret by key |
| `GrafanaNotificationPolicy` — root | ✓ | | Single tree root per stack; default catch-all routing |
| `GrafanaNotificationPolicyRoute` — leaf | | ✓ | Leaf routes by label match; attaches to platform's root tree |
| `GrafanaMuteTiming` — shared windows | ✓ | | Maintenance windows affecting all teams |
| `GrafanaMuteTiming` — team-specific | | ✓ | Per-team maintenance (e.g., aegis deploy window) |

### Exceptions and edge cases

Some failure modes cross the domain boundary. The rule is prose, not a table:

- **Platform concerns that are service-adjacent**. A service pod evicted due to OOM is observed via a platform-owned `PrometheusRule` (`kube_pod_status_reason{reason="OOMKilled"}`) — platform wrote the rule once; every namespace inherits it. But the *notification* goes to the service team whose pod was killed, via label-based routing in `GrafanaNotificationPolicyRoute`.
- **Service concerns that are platform-adjacent**. An aegis-core certificate issued by cert-manager fails to renew. cert-manager is platform-owned, so the `CertificateNotReady` alert is platform-owned. The notification routes to the service team whose certificate is affected because they are the signal consumer.

The principle that resolves both:

> **The team that understands the failure mode owns the alert rule; the team that consumes the signal gets the notification.**

Routing is label-driven, not rule-duplicating. Platform rules carry `namespace` / `team` labels; service-team `GrafanaNotificationPolicyRoute` resources match on those labels and route to the service team's contact point.

## Secret plumbing model

Service-team `GrafanaContactPoint` resources reference webhook URLs, but webhook URLs never embed directly in service-repo YAML. Two reasons: (a) secret rotation becomes a cross-repo coordination event rather than a platform-only operation; (b) the service repo becomes a discovery target for any leaked git history search.

Instead, service teams reference platform-provided Kubernetes Secrets by key:

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaContactPoint
metadata:
  name: aegis-oncall-slack
  namespace: aegis
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  name: aegis-oncall-slack
  type: slack
  settings:
    url: ""  # populated from secret
  valuesFrom:
    - targetPath: "settings.url"
      valueFrom:
        secretKeyRef:
          name: team-webhooks
          key: slack-aegis
```

Platform responsibility: provision a single `team-webhooks` Kubernetes Secret via External Secrets Operator, backed by SSM Parameter Store paths `/aegis/<env>/grafana-cloud/team-webhooks-*`. Each team gets one key inside the Secret.

**New team onboarding**:

1. Platform adds `/aegis/<env>/grafana-cloud/team-webhooks-<newteam>-slack` in SSM PS.
2. Platform updates External Secret manifest to include new key in the `team-webhooks` Secret.
3. Platform grants the service team read access to their specific key (RBAC `resourceNames` hardening path).
4. Service team's `GrafanaContactPoint` references the new key.

This is the friction point of platform-owned multi-tenant secrets: adding a team requires a platform PR before the service team can ship their contact point. It is the cost we accept to keep webhook URLs out of service repos.

## Notification policy tree composition

Grafana Cloud Alertmanager enforces a **single** notification policy tree per stack. The tree cannot be sharded across multiple operators; concurrent writers race and the last writer wins.

Composition contract:

- **Root** is platform-owned. Exactly one `GrafanaNotificationPolicy` resource exists in the cluster, and it is in the platform namespace. The root defines defaults: `severity=critical` → `platform-oncall`, `namespace=aegis` → fall through to aegis routes, unmatched → `platform-oncall` catch-all.
- **Leaves** are service-team-owned. Each `GrafanaNotificationPolicyRoute` resource attaches to the platform root via label selector (`routeSelector` matches `tree=aegis-root`) and declares its own match predicates (`namespace=aegis`, `severity=warning`, etc.).
- **grafana-operator** reconciles the composed tree — root plus all matching leaf routes — into Grafana Cloud's single notification policy. Service teams write to their own leaf; they never edit the root.

Root is read-only to service teams (a platform PR is required to touch it). Leaf additions are service-team PRs that cannot touch the root. A malformed service-team leaf breaks only its own route — grafana-operator rejects the leaf CRD without invalidating the tree.

## Cross-repo contract: the 5 CRDs aegis-core ships

The platform-surface contract between landing-zone and aegis-core consists of five CRDs that aegis-core (or any future workload team) declares and ArgoCD syncs into the target cluster:

1. **`ServiceMonitor` / `PodMonitor`** — scrape target declarations.
2. **`PrometheusRule`** — service alert rules and recording rules.
3. **`GrafanaDashboard`** — service dashboards (RED metrics, business KPIs).
4. **`GrafanaContactPoint`** — service notification destinations (references platform-provided Secret keys).
5. **`GrafanaNotificationPolicyRoute`** — service routing leaves attaching to the platform root.

All five ship from aegis-core's `k8s-manifests/observability/` directory, synced via aegis-core's ArgoCD app-of-apps into the target cluster.

### Contract stability commitment

Changes that shift CRD ownership or break existing service-team manifests require a `cross-repo/blocking` issue on aegis-core before the landing-zone PR lands. Today's contract change — widening from ADR-015's narrow 3 CRDs (`ServiceMonitor` / `PodMonitor` / `PrometheusRule`) to the current 5 — is itself such an event. It is tracked on aegis-core #46, which this ADR and [ADR-022](022-observability-backend-grafana-cloud.md) escalate from `cross-repo/fyi` to `cross-repo/blocking`.

## Migration safety

This ADR's largest value is **backend-agnostic contract stability**. When [ADR-021](021-observability-scaling-path.md) rung-3 triggers fire and the project migrates from Grafana Cloud free tier to AMP + AMG, the diff is:

| Surface | Grafana Cloud | AMP + AMG | Migration diff |
|---|---|---|---|
| aegis-core `PrometheusRule` CRD | ✓ | ✓ | **zero** |
| aegis-core `ServiceMonitor` CRD | ✓ | ✓ | **zero** |
| aegis-core `GrafanaDashboard` CRD | grafana-operator → GC | grafana-operator → AMG | **zero** (target swap only) |
| aegis-core `GrafanaContactPoint` CRD | grafana-operator → GC | grafana-operator → AMG | **zero** |
| aegis-core `NotificationPolicyRoute` CRD | grafana-operator → GC | grafana-operator → AMG | **zero** |
| Alloy `remote_write` + auth | GC URL + API token | AMP URL + SigV4 IRSA | URL + auth block replaced |
| `Grafana` CRD target | GC stack + API token | AMG workspace + SA token | One CRD manifest replaced |
| External Secret source paths | `/aegis/<env>/grafana-cloud/*` | `/aegis/<env>/amp-amg/*` | Path renames |
| IRSA for metric push | Not needed (API key) | Required (`aps:RemoteWrite`) | New IRSA role added |
| Terraform resources | Grafana Cloud provider | `aws_prometheus_workspace` + `aws_grafana_workspace` | New TF layer |

**aegis-core experiences zero changes**. The platform repo sees a focused migration PR — a day's work at rung-3 scale, not a cross-repo refactor.

### The one architectural choice at migration time

AMP and AMG are two separate AWS services with two separate alerting subsystems:

- **α. AMG-managed alerting** (Grafana-managed Alertmanager, CRD-compatible with grafana-operator). Contract preserved end-to-end.
- **β. AMP native alertmanager** (Alertmanager API on AMP itself, bypasses grafana-operator for routing). Routing CRDs (`GrafanaContactPoint`, `GrafanaNotificationPolicyRoute`) no longer apply; routing migrates to AMP's alertmanager config API. `PrometheusRule`, `ServiceMonitor`, `PodMonitor`, `GrafanaDashboard` remain unchanged.

This ADR presupposes α at migration time. If β is forced by tighter IAM boundaries or compliance constraints, the contract takes a localized break on the two routing CRDs only, not the full 5-CRD surface. Service teams would need to migrate their contact points and policy routes to AMP alertmanager YAML — unpleasant but bounded.

## Alternatives Considered

### Platform owns everything

Platform team writes all alert rules, dashboards, contact points, and routing on behalf of service teams.

Rejected. Removes service-team SLO ownership; on-call culture cannot form because the team paged does not own the rule that pages them. "Gated platform" anti-pattern: every service change that needs new instrumentation blocks on a platform PR. Does not scale beyond one service team.

### Service team owns everything

Service teams write their own platform alerts (`NodeNotReady`, `KubePodCrashLooping`, etc.) alongside their service alerts.

Rejected. Every team reinvents the platform alert set; cardinality explodes because the same metric is monitored from N namespaces; alert duplication generates noise. "No platform" anti-pattern: the platform team's job becomes writing docs about what rules everyone should copy-paste, and they all drift.

### Domain split by repo rather than by concern type

Any rule living in landing-zone is platform; any rule living in aegis-core is service.

Rejected. The decision driver is "who understands the failure," not which repo the YAML lives in. Cross-cutting concerns — e.g., platform alert on service pod OOM, service alert on cert-manager certificate failure — force either duplication across repos or awkward ownership transfers. The concern-type split resolves these cleanly; the repo split does not.

## Consequences

### What changes in the repository

- **Contract surface widens** from ADR-015's narrow Discovery contract (3 CRDs) to the current 5-CRD model.
- **Dashboard storage shifts** from ConfigMap-with-`grafana_dashboard: "1"`-label (the kube-prometheus-stack pattern) to `GrafanaDashboard` CRDs reconciled by grafana-operator. Historical dashboards that used the ConfigMap pattern need one-time re-export as `GrafanaDashboard` CRDs.
- **Secret model introduced**: service teams reference platform-provided `team-webhooks` Kubernetes Secret keys via `secretKeyRef`. Webhook URLs never appear in aegis-core YAML.

### Cross-repo impact

- aegis-core #46 body is substantially rewritten to reflect the 5-CRD surface, not the 3-CRD surface.
- aegis-core #46 label escalates from `cross-repo/fyi` to `cross-repo/blocking`.
- aegis-core acknowledgement of the new scope is a prerequisite for landing [ADR-022](022-observability-backend-grafana-cloud.md)'s implementation PRs (Alloy + grafana-operator + External Secrets).

### Backward compatibility

aegis-core has not yet shipped any observability manifests (per #46 "What aegis-core needs to decide — non-blocking"). The widened contract is therefore net-new scope, not a breaking change to existing manifests. There is no migration for service-team YAML because there is no service-team YAML yet.

### Forward extensibility

Adding a new workload team to the cluster is a mechanical process:

1. Platform adds `/aegis/<env>/grafana-cloud/team-webhooks-<newteam>-slack` to SSM PS.
2. Platform extends External Secret to include the new key in `team-webhooks`.
3. Platform grants `resourceNames`-scoped read access on the Secret.
4. Service team ships the 5 CRDs in their repo, referencing the new webhook key.

No ADR change is needed for team additions — the contract is structurally multi-tenant.

## Known Limitations

1. **Enforcement is cultural, not mechanical**. Nothing in the cluster prevents aegis-core from shipping a `PrometheusRule` named `NodeNotReady` that duplicates a platform rule. Kyverno policy enforcement (restricting which namespaces can create which CRD kinds) is available and listed as a future hardening step; today's enforcement is PR review.
2. **Root `GrafanaNotificationPolicy` is platform-only**. If a service team needs an urgent change to the default routing (e.g., add a new severity tier), they cannot self-serve — a platform PR is required. Mitigated by keeping the root minimal: leaf routes cover most real routing needs.
3. **`team-webhooks` Secret coupling**. All teams read the same Secret resource via different keys. RBAC cannot restrict on individual keys by default; the hardening path uses `resourceNames` to restrict which team can read which ServiceAccount-scoped Secret. Today the coupling is accepted for simplicity.
4. **Meta-observability is platform-owned by definition**. "grafana-operator failed to reconcile" is a platform alert — service teams have no visibility into the observability stack's own failures. If grafana-operator silently stops reconciling service-team CRDs, the service team learns about it by noticing their alerts stopped firing, not by a dedicated signal. Platform is expected to watch its own meta-observability carefully.
5. **Dashboard ownership ambiguity at domain boundaries**. A dashboard showing "aegis-core pod CPU usage" uses a platform metric (`container_cpu_usage_seconds_total`) filtered by a service namespace. The convention: platform-only metrics → platform; any join with service-specific labels → service team; truly ambiguous cases resolved via ADR amendment rather than case-by-case debate.

## Related

- [ADR-015](015-observability-tooling.md) (superseded) — original narrow Discovery contract; this ADR formalizes and widens the principle.
- [ADR-021](021-observability-scaling-path.md) (amended) — scaling ladder; the stability of *this* contract is why the ladder's rung transitions are workable at all.
- [ADR-022](022-observability-backend-grafana-cloud.md) — current backend choice; this ADR defines the contract preserved when that backend eventually swaps.
- aegis-core #46 — cross-repo coordination; contract surface widened per this ADR, label escalated to `cross-repo/blocking`.
