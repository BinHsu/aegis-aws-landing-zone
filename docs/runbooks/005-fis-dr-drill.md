<!-- session-close-review: experiment template ID + stop condition alarm name match current `terraform output` in staging/fis -->
# Runbook 005 — FIS DR drill (primary EKS node outage)

> **When to read this**: you are about to run the FIS DR drill defined in [ADR-020](../decisions/020-fis-dr-drill.md). Reading in full takes <5 minutes. Skipping pre-flight section is the most common way this drill goes wrong — do not skip.

## Pre-flight (do NOT skip)

### 0. Prerequisite state

| Layer | Required state | How to verify |
|---|---|---|
| `staging/network` | applied, VPC + NAT up | `gh workflow run terraform-apply-workload.yml` path |
| `staging/platform` | applied, EKS cluster Ready, Alloy Running | `kubectl --context aegis-staging-primary get nodes` → ≥1 node Ready; `kubectl -n monitoring get pods -l app.kubernetes.io/name=alloy` → Running |
| `staging/workloads` | applied, aegis namespace + GuardDuty present | `kubectl -n aegis get all` shows workload Services; `aws guardduty list-detectors --region eu-central-1` returns the staging detector |
| `staging/observability` | applied, grafana-operator Running | `kubectl -n observability get pods -l app.kubernetes.io/name=grafana-operator` → Running |
| `staging/fis` | applied, experiment template exists | `terraform -chdir=terraform/environments/staging/fis output experiment_template_id` returns an ID |

If any row fails, the drill cannot produce useful signal. Apply missing layers before continuing.

### 1. Verify observability can see the cluster

Open `https://<org_slug>.grafana.net` in a browser and sign in via Google OAuth (per Runbook 006 Part 3 break-glass admin). Org slug is `config.grafana_cloud.org_slug` — `aegis-staging` by default.

Open **Dashboards → Kubernetes / Compute Resources / Cluster** (platform dashboard shipped by staging/observability/platform-dashboards.tf). You should see CPU + memory series for both cluster nodes, with the `cluster` label populated (value `primary` or `slave_1` per ADR-022 §External label). If series are flat at zero or the `cluster` label is missing, Alloy is not remote-writing — fix before drilling.

Under ADR-022, `node-exporter` is no longer a separate DaemonSet. Node-level metrics come from kubelet's cAdvisor + kube-state-metrics (both scraped by Alloy via ServiceMonitors). Incident 27's Fargate-affinity pattern no longer applies.

### 2. Verify the `NodeNotReady` alert rule is loaded

In Grafana Cloud: **Alerting → Alert rules**. Filter by label `drill=fis-primary-outage`. You should see one rule: `NodeNotReady`, state = Normal.

Rule is platform-owned and ships from `staging/observability/platform-alerts.tf`. If missing, re-apply the observability layer.

### 3. Verify the stop-condition alarm is NOT in ALARM state

```bash
aws cloudwatch describe-alarms \
  --alarm-names aegis-staging-fis-abort-eks-api-failures \
  --region eu-central-1 \
  --query 'MetricAlarms[0].StateValue'
```

Expected: `"OK"` (or `"INSUFFICIENT_DATA"` if the cluster was recently applied — wait 3 minutes for metrics to populate). If the state is `"ALARM"` before you start, FIS will abort the experiment the moment it starts.

### 4. Know your recovery signal

During the drill, the operator's only required action is **wait**. Auto-recovery is built in. But know your manual-override path in case something goes wrong:

```bash
# List stopped instances in primary VPC
aws ec2 describe-instances \
  --filters "Name=tag-key,Values=karpenter.sh/nodepool" "Name=instance-state-name,Values=stopped" \
  --region eu-central-1 \
  --query 'Reservations[].Instances[].InstanceId' --output text

# If FIS auto-recovery fails, manually start them
aws ec2 start-instances --instance-ids <ids> --region eu-central-1
```

## Start the drill

### 1. Start the experiment

```bash
EXPERIMENT_TEMPLATE_ID=$(terraform -chdir=terraform/environments/staging/fis output -raw experiment_template_id)

aws fis start-experiment \
  --experiment-template-id "$EXPERIMENT_TEMPLATE_ID" \
  --region eu-central-1
```

Note the returned `experiment.id` (opaque string like `EX123ABC`). You'll use it to monitor state.

### 2. Confirm experiment is Running

```bash
aws fis get-experiment --id <experiment-id> --region eu-central-1 \
  --query 'experiment.state.status'
```

Expected progression: `initiating` → `running` (within ~30 seconds). If it goes straight to `stopped` or `failed`, read `experiment.state.reason` — common causes:

- Stop-condition alarm in ALARM state (see pre-flight step 3)
- IAM role trust policy mismatch (shouldn't happen with this Terraservice; re-apply `staging/fis` if it does)
- Target-resolution-mode failed (no instances matching tag filter — cluster is empty or tag is wrong; re-apply `staging/platform`)

## During the drill (10 minutes)

### What you should see in Grafana

- **Kubernetes / Compute Resources / Cluster**: CPU + memory series drop toward 0 within 1–2 minutes (nodes stop reporting metrics as kubelet goes offline)
- **Alerting → Alert rules → NodeNotReady**: transitions Normal → Pending (after ~1 min) → Firing (after 2 min)
- **Kubernetes / Nodes (Pods)**: pod count per node drops as pods enter Pending

### What you should see in kubectl

```bash
kubectl --context aegis-staging-primary get nodes
# within 2-3 min: all nodes → NotReady

kubectl --context aegis-staging-primary get pods -n aegis
# pods → Pending (ContainerCreating stuck, no nodes to schedule on)

kubectl --context aegis-staging-primary get pods -n kyverno
kubectl --context aegis-staging-primary get pods -n cert-manager
# same pattern — everything worker-hosted is stuck
```

Control-plane-hosted pods (Karpenter, ArgoCD, coredns addon) on Fargate continue running — their nodes are not affected by this drill.

### Demonstrable moments for an interviewer

1. **Pre-drill state**: Grafana green, all pods Running, alerts Normal → show baseline
2. **T+2min — failure visible**: nodes NotReady, pods Pending, `NodeNotReady` alert Firing
3. **T+5min — in full failure mode**: all primary-region workload capacity gone
4. **T+10min — experiment ends automatically**: FIS starts instances, Karpenter re-onboards
5. **T+12-13min — full recovery**: all pods back to Running, alert resolves

## Post-drill (T+13min onward)

### 1. Verify all nodes Ready

```bash
kubectl --context aegis-staging-primary get nodes
```

Expected: all nodes → Ready. If any are still NotReady after 15 minutes:

- Check the instance is actually started: `aws ec2 describe-instances --instance-ids <id> --query 'Reservations[0].Instances[0].State.Name'`
- Check Karpenter didn't create orphan NodeClaims: `kubectl get nodeclaim -A`

### 2. Verify all pods Running

```bash
kubectl --context aegis-staging-primary get pods -A | grep -vE "Running|Completed"
```

Expected: empty output (or the two DaemonSet pods that are known to not schedule on Fargate — node-exporter handled by PR #110, GuardDuty runtime agent is a known gap per Incident 28 / improvements/010).

### 3. Verify alert resolved

In Grafana Cloud: **Alerting → Alert rules**. Filter by label `drill=fis-primary-outage`. The `NodeNotReady` rule should be state = Normal again.

Under ADR-022, Prometheus is no longer in-cluster — there is no `kube-prometheus-stack-prometheus` Service to port-forward. Alert rule evaluation happens server-side at Grafana Cloud Mimir ruler.

### 4. Record the drill

Create a dated entry in the session log (wherever you keep it — not committed to this repo). Record:

- Experiment ID
- Start time / end time
- Actual observed T+2/T+5/T+10/T+13 timing vs planned
- Any deviations from expected behavior
- Any resources still not recovered (e.g., Incident 28 agents)

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `aws fis start-experiment` returns immediately with `state.status=failed` | Stop-condition alarm in ALARM state OR IAM trust policy bad | Check CloudWatch alarm; re-apply `staging/fis` |
| Experiment starts but nodes never enter NotReady | Tag filter mismatch — instances don't have `karpenter.sh/nodepool` | Verify via `aws ec2 describe-instances` + tag query |
| Alert `NodeNotReady` fires but Grafana Alert panel is empty | Grafana alerting data source not wired to Prometheus | Check Grafana **Data Sources** → Prometheus URL |
| Experiment ends but instances stay stopped | `startInstancesAfterDuration` parameter not honored; AWS occasional issue | Manual `aws ec2 start-instances --instance-ids <ids>` |
| After recovery, Karpenter does not re-onboard instances | NodeClaim created for replacement but original is returning — duplicate node | `kubectl delete nodeclaim` for the orphan claim; Karpenter will clean up |
| Stop-condition alarm fires mid-drill unexpectedly | EKS API under genuine stress from concurrent incident | Investigate cluster — this is the alarm working correctly; the drill's auto-abort protected the environment |

## When to NOT run this drill

- **During a production incident** or when the cluster is already in a degraded state. The stop-condition alarm should protect, but don't rely on it.
- **Before a demo where the drill is the demo**. Do it once in advance to catch any config drift, then run it "fresh" for the audience. A drill running for the first time ever in front of an interviewer is a double-risk event.
- **Without the `staging/workloads` observability stack applied**. Without Grafana/Prometheus/alert rules, you get a failure with no visible signal — worthless for demo, unhelpful for learning.

## References

- [ADR-020 — FIS for DR drills](../decisions/020-fis-dr-drill.md) — design rationale + alternatives considered
- [ADR-018 — Multi-region EKS](../decisions/018-multi-region-eks-design.md) — the architecture this drill exercises
- [Incidents 26–30](../incidents.md) — bugs surfaced by Session C cold apply; the drill is expected to not re-expose these post-fix
