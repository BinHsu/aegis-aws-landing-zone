# 020. Fault Injection Simulator (FIS) for DR drills

## Status
Accepted (amended 2026-04-21: observation path mechanism updated per [ADR-022](022-observability-backend-grafana-cloud.md); alert rule itself unchanged)

## Context

Phase 4c delivered multi-region EKS (ADR-018, slot pattern) and confirmed the code path works (Session C, 2026-04-20: length-2 apply + both clusters Ready + teardown clean). What remains undemonstrated is the **dynamic failure-mode observation**: what actually happens during a region-scale event? Does observability reflect it? Do the alerts fire? How long does recovery take?

A portfolio project that claims multi-region posture without a live DR drill is asserting a capability it has not exercised. The ISO 27001 Annex A.5.30 (ICT readiness for business continuity) framing the project cites in ADR-005 — change management and continuity controls — is hollow if the continuity path has never been activated.

### Constraints

- **Single operator, lab budget**. Drills must cost pennies, not dollars.
- **Reversible**. A failed drill must not stuck the cluster or require a teardown-reapply cycle to recover.
- **Demonstrable**. An interviewer should be able to see the failure happen in Grafana, the alert fire, the recovery observed, all within 10–15 minutes of elapsed time.
- **Version-controlled**. The project's posture is "every AWS resource is in Terraform." A DR drill tool that lives as a clicked-into-existence Console template would be the project's only exception — politically inconsistent.
- **Least-privilege IAM**. The drill's service role must not be able to damage anything outside the Karpenter-provisioned node set.

## Decision

**AWS Fault Injection Simulator (FIS)**, with an experiment template that stops primary-region Karpenter-provisioned EKS worker nodes for 10 minutes. Recovery is automatic: FIS's `startInstancesAfterDuration` parameter auto-starts the stopped instances when the experiment ends.

The FIS layer is a new Terraservice at `terraform/environments/staging/fis/`, with four components:

- `aws_fis_experiment_template` — the experiment definition (target selector, action, duration, stop condition)
- `aws_iam_role "fis"` — service role FIS assumes during execution, with tag-scoped deny-by-default on EC2 actions
- `aws_cloudwatch_metric_alarm` — stop condition that aborts the experiment if EKS API server enters reconcile-storm territory
- `terraform output` — copy-pasteable `aws fis start-experiment` command for the operator

### Experiment mechanics

| Axis | Choice |
|---|---|
| Target | EC2 instances tagged `karpenter.sh/nodepool=aegis-default`, state=running |
| Action | `aws:ec2:stop-instances` (not terminate — preserves instance state for auto-restart) |
| Duration | 10 minutes (via `startInstancesAfterDuration=PT10M`) |
| Stop condition | CloudWatch alarm on primary EKS API server latency > 2s for 2 minutes |
| Recovery | Automatic — FIS starts the stopped instances when the duration elapses |

### What the drill demonstrates

- **Observability signal path**: `NodeNotReady` PrometheusRule (originally authored in `staging/workloads/modules/eks-workloads/observability.tf` for the kube-prometheus-stack era; now forwarded by Alloy to Grafana Cloud Mimir ruler for server-side evaluation per [ADR-022](022-observability-backend-grafana-cloud.md)) fires within 1–2 minutes of node stop, visible in Grafana Cloud's Alert panel.
- **Recovery path**: Karpenter detects the instances returning, re-onboards them to the node pool, pods reschedule. Full recovery within 2–3 minutes of experiment end.
- **Governance plumbing**: the stop-condition alarm is the demonstrable mechanism that the drill itself is monitored — if something goes wrong, FIS aborts and restarts the instances.

## Alternatives Considered

### Manual `aws ec2 stop-instances` + stopwatch

Simplest possible DR drill: operator runs the CLI, watches the clock, runs start-instances 10 minutes later. Rejected because (a) no audit trail — the experiment is not recorded anywhere, (b) no automatic recovery if the operator is interrupted, (c) no stop condition, (d) nothing reusable by another operator, (e) the portfolio signal is "I clicked commands," not "I designed a controlled drill."

### Litmus / Chaos Mesh / Chaos Toolkit (in-cluster chaos engineering)

Open-source chaos engineering controllers that inject failures via Kubernetes CRDs. More granular (can kill specific pods, inject network latency, corrupt disk). Rejected for Phase 4c because the failure mode we want to demonstrate is **infrastructure-level**, not pod-level. Stopping a pod with chaos-mesh is pod-scheduler-friendly (Kubernetes reschedules immediately, barely visible). Stopping the node the pod runs on — and removing capacity for *all* pods on that node — is what matches the "region experienced capacity loss" narrative. FIS natively targets AWS infrastructure; chaos-mesh targets in-cluster resources. Different tools for different layers; FIS fits the Phase 4c "infra-level" framing.

Future Phase 5 (service mesh) might bring chaos-mesh in for pod-level traffic-fault injection. Complementary, not duplicative.

### Cross-region stop condition via CloudWatch Metric Streams

The original demo concept watched Region B's load metrics — if Region B was overwhelmed picking up primary's traffic, the experiment would abort to protect Region B. Rejected for Phase 4c because:

- FIS stop-condition alarms must live in the same region as the experiment
- Cross-region observability requires CloudWatch Metric Streams ($1/month base + Kinesis Data Firehose per-GB costs)
- ~3 hours of additional Terraform to wire up
- The demo value of "we have a multi-region stop condition" is marginal over "we have a same-region stop condition with a clearly-designed threshold"

Tracked as a Phase 5 consideration if cross-region observability lands for other reasons (e.g., centralized logging).

### S3 / CloudFront fault (Origin Group failover)

The original concept also included a second parallel action: inject an IAM deny on the role CloudFront uses to read S3, forcing Origin Group failover to a Region B bucket. Rejected because (a) CloudFront OAC doesn't use an IAM role in the standard sense — access is via service principal + bucket policy, so `aws:fis:inject-api-internal-error` targeting an IAM role doesn't apply; (b) the alternative of SSM Automation temporarily modifying the bucket policy is a new scope surface; (c) CloudFront TTL would require manual cache invalidation before the drill for the fault to be visible — an extra operational wrinkle; (d) the primary EKS-node drill alone is sufficient to exercise the observability + alert + recovery story.

Tracked for a future Phase 5 drill once Origin Group is added to `staging/edge/`.

### Terminate vs Stop

`aws:ec2:terminate-instances` is more dramatic (the instance is gone forever), but (a) Karpenter would immediately try to replace the terminated instances, fighting with the failover narrative, and (b) there is no auto-recovery — the experiment cannot start what it terminated. `stop-instances` is the correct semantics: temporarily remove capacity, durable recovery via `startInstancesAfterDuration`.

## Consequences

### Cost

- Experiment template: $0 to exist
- Per-experiment-action execution: ~$0.0095 per instance-action (negligible)
- The 10-minute capacity loss is free (stopped EC2 is not billed)
- CloudWatch alarm: $0.10/month
- Total: **< $0.15/month always-on + < $0.01 per drill**

### Operational burden

- Pre-drill runbook step: run `aws fis start-experiment` with the template ID
- Mid-drill observation: Grafana + kubectl (existing tooling)
- Post-drill: verify all nodes Ready, pods running; `kubectl get pods -A` smoke check
- Drill cadence: quarterly recommended; ISO 27001 A.5.30 does not mandate a cadence

### Blast radius

The FIS service role is scoped to `karpenter.sh/nodepool`-tagged instances via an inline deny policy (iam.tf). The managed policy `AWSFaultInjectionSimulatorEC2Access` provides the happy-path permissions; the inline policy intersects it with the tag condition. An operator or attacker who assumed this role could not damage non-Karpenter infrastructure (control-plane VPC ENIs, ArgoCD nodes on Fargate, etc.).

### What this does NOT cover

- **Prod drills**. The experiment template lives in the staging account only. A prod-account FIS layer is deferred until prod workloads exist — today prod is empty.
- **Control-plane failures**. Stopping worker nodes does not exercise EKS control-plane failure modes (master endpoint unreachable, API server down). AWS does not offer FIS actions for control-plane fault injection — that's a managed-service limitation, not a design choice.
- **Full region outage**. The drill removes worker capacity only. NAT gateway, ALB, Karpenter controller (on Fargate), ArgoCD, observability stack all continue to run. A true region outage would take all of these down simultaneously, and the drill for that class of failure requires manually degrading each layer or using a region-level IAM deny (not a FIS action).

### Portfolio signal

The explicit ADR + runbook + Terraform-defined experiment closes the loop on ADR-018 (multi-region EKS design): the design now has a corresponding *exercise*. An interviewer can read this ADR, see the drill artifact, and either run the drill themselves (if they have access) or read the runbook output that the operator has captured.

## Related

- [ADR-005](005-compliance-framework-iso-27001.md) — ISO 27001 posture; A.5.30 ICT readiness maps to this drill
- [ADR-015](015-observability-tooling.md) (superseded 2026-04-21 by [ADR-022](022-observability-backend-grafana-cloud.md)) — signal path the drill exercises
- [ADR-018](018-multi-region-eks-design.md) — multi-region EKS slot pattern; this drill is its dynamic counterpart
- `docs/runbooks/005-fis-dr-drill.md` — execution runbook (pre-flight, start, observe, post-check)
- `docs/improvements/008-workload-multi-region.md` — Mode A / Mode B operational modes; the drill applies to both
