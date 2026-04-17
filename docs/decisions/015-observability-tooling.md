# 015. Observability Tooling

## Status
Accepted

## Context

Phase 3c delivered a working EKS cluster, but with no metrics collection, no dashboards, and no alerting. The EKS control plane logs flow to CloudWatch (enabled at cluster creation), but there is no cluster-level or workload-level observability. An operator debugging at 2 AM has `kubectl` and guesswork.

Phase 4b adds an observability stack. The decision is which stack.

### Requirements

1. **Cluster metrics**: node CPU/memory, pod status, Karpenter provisioning decisions, control plane health.
2. **Workload metrics**: aegis-core gateway/engine request rates, latencies, error rates (when the workload arrives in 4a'').
3. **Dashboards**: browser-accessible, no CLI gymnastics to view metrics.
4. **Alerting foundation**: the ability to define alert rules (e.g., `apiserver_requested_deprecated_apis > 0` per the change-review-discipline doc §3.4). Alerting destinations (PagerDuty, Slack) are out of scope for the lab.
5. **Cost discipline**: must tear down cleanly with the platform layer. Persistent costs when torn down should be < $2/month.
6. **Portability**: the observability stack should transfer to any Kubernetes cluster, not just EKS. This is a portfolio project demonstrating general cloud-native skills, not AWS-specific integrations.

### Bin's existing experience

Bin has 3 years of Prometheus → Grafana operational experience: 12 alert rules deployed as Helm → ConfigMap → sidecar reload pipeline. This is not new territory — it is a consolidation of existing skills onto the EKS platform. The learning goal is integration with ArgoCD (GitOps-managed observability), not Prometheus itself.

## Decision

**`kube-prometheus-stack` Helm chart, deployed via ArgoCD app-of-apps.**

`kube-prometheus-stack` is the community-maintained Helm chart that bundles:
- **Prometheus Operator** — CRD-based Prometheus lifecycle management (`ServiceMonitor`, `PrometheusRule`, `Alertmanager`)
- **Prometheus** — metrics scraping and storage
- **Grafana** — dashboards, with 20+ pre-built Kubernetes dashboards included
- **node-exporter** — host-level metrics (CPU, memory, disk, network per node)
- **kube-state-metrics** — Kubernetes object state as metrics (pod phase, deployment replicas, etc.)
- **Default alert rules** — KubeContainerWaiting, KubePodCrashLooping, NodeNotReady, etc.

This chart is the de facto standard for single-cluster Kubernetes observability. It provides a complete stack in one Helm release, with sensible defaults and extensive customization via `values.yaml`.

### Deployment model

- **ArgoCD Application** in `apps/staging/` (aegis-core repo) pointing at the `kube-prometheus-stack` Helm chart from the `prometheus-community` repo.
- **Namespace**: `monitoring` (created by ArgoCD's `CreateNamespace=true` — no Terraform-managed IRSA or NetworkPolicy dependency for the monitoring namespace, unlike the `aegis` workload namespace).
- **Grafana Ingress**: AWS Load Balancer Controller provisions an ALB with ACM TLS (same pattern as future aegis-core ingress). Grafana is accessible via browser for the operator.
- **Prometheus storage**: 20 GB `gp3` PersistentVolumeClaim. Acceptable to lose on teardown — lab metrics have no retention requirement. The PVC is created by Prometheus Operator; Karpenter schedules the pod on a node with EBS access.
- **Retention**: 24 hours in-cluster (sufficient for a 4-hour session with margin). No long-term storage (Thanos/Mimir/Cortex are out of scope).

### Cost

| Component | Hourly (on Spot) | Per 4h session | Persistent when torn down |
|---|---|---|---|
| Prometheus + Grafana pods (~1 vCPU, 2 GB) | ~$0.03 | ~$0.12 | $0 (pods gone) |
| node-exporter DaemonSet (minimal per-node) | ~$0.01 | ~$0.04 | $0 |
| kube-state-metrics (tiny) | negligible | negligible | $0 |
| Grafana ALB | ~$0.02 | ~$0.08 | $0 (ALB deleted with Ingress) |
| EBS PVC (20 GB gp3) | $0.003 | $0.01 | $1.60/month if not deleted |

**Total per session: ~$0.25.** Well within budget. The EBS PVC is the only persistent cost; destroying it on teardown (accepting metric loss) keeps monthly costs at zero.

## Alternatives Considered

**Amazon CloudWatch Container Insights.** Rejected. Container Insights costs $0.30 per node per hour for enhanced observability, which is $1.20/hour for a 4-node lab cluster — more than the entire Phase 3 baseline. Standard observability is cheaper but provides limited dashboards (no custom Grafana panels, no PromQL). Metrics are stored in CloudWatch Metrics at $0.30/metric/month for the first 10K — the combinatorial explosion of Kubernetes labels easily generates thousands of metrics. Additionally, Container Insights is AWS-only: the skills do not transfer to GKE, AKS, or bare-metal Kubernetes. For a portfolio project, vendor-neutral tooling is worth more than the convenience of a managed service.

**Datadog.** Rejected. Datadog's free tier allows 5 hosts, which covers the lab, but the agent sends data to Datadog SaaS — introducing an external data dependency, requiring API key management, and demonstrating a vendor integration rather than an operational skill. The monthly cost for even one node on the Pro plan ($23/host/month) exceeds the entire project's monthly budget. A portfolio piece should demonstrate that the engineer can build observability, not purchase it.

**Grafana Cloud free tier.** Considered. Grafana Cloud's free tier offers 10K metrics series and 50 GB logs — sufficient for the lab. However, it still sends data to a SaaS endpoint, requires a Grafana Cloud API key, and the scraping is done by Grafana Alloy (the agent), not Prometheus. The value proposition over self-hosted kube-prometheus-stack is managed Grafana — but for a single-cluster lab, self-hosting Grafana is trivial and demonstrates more skill than configuring a SaaS agent. Grafana Cloud would be the right choice for a team that wants to avoid Prometheus operations; this project intentionally opts in to Prometheus operations as a portfolio artifact.

**Prometheus + Grafana without the Operator (raw Helm charts).** Considered. Installing `prometheus` and `grafana` Helm charts separately is simpler conceptually but loses the Operator's CRD-based lifecycle management (`ServiceMonitor`, `PrometheusRule`). Without the Operator, scrape targets are configured via Prometheus `scrape_configs` (static YAML), which does not integrate with ArgoCD's GitOps model as cleanly. The `kube-prometheus-stack` chart is larger but provides a coherent, tested bundle with all the CRDs pre-configured. The additional complexity is in the chart, not in the operator's mental model.

## Consequences

The `monitoring` namespace becomes a platform-provided namespace alongside `argocd` and `karpenter`. Unlike `aegis`, it is not Terraform-managed — ArgoCD creates it and owns its lifecycle.

Workload teams (aegis-core) expose metrics by creating `ServiceMonitor` CRDs that target their pods. The Prometheus Operator discovers these monitors automatically. This is a clean contract: the platform provides Prometheus; the workload declares what to scrape.

The `apiserver_requested_deprecated_apis` alert rule (from `docs/principles/change-review-discipline.md` §3.4) can now be implemented as a `PrometheusRule` CRD in the kube-prometheus-stack values. This closes the gap between "we should detect deprecated APIs" and "we actually do."

Grafana dashboards are ephemeral — they are provisioned from the chart's built-in set and any ConfigMap-based custom dashboards. No persistent Grafana database. This is intentional: dashboards-as-code via Helm values is the GitOps-native pattern and avoids the "someone edited a dashboard in the UI and it was lost on restart" anti-pattern.

The 24-hour in-cluster retention means metrics from previous sessions are not available. This is acceptable for a lab. If longer retention becomes useful (e.g., for week-over-week comparison), Thanos sidecar or remote-write to S3 can be added in a future phase without changing the core stack.
