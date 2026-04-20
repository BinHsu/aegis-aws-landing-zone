<!-- session-close-review: experiment template ID + stop condition alarm name match current `terraform output` in staging/fis -->
# Runbook 005 — FIS DR drill (primary EKS node outage)

> **When to read this**: you are about to run the FIS DR drill defined in [ADR-020](../decisions/020-fis-dr-drill.md). Reading in full takes <5 minutes. Skipping pre-flight section is the most common way this drill goes wrong — do not skip.

## Pre-flight (do NOT skip)

### 0. Prerequisite state

| Layer | Required state | How to verify |
|---|---|---|
| `staging/network` | applied, VPC + NAT up | `gh workflow run terraform-apply-workload.yml` path |
| `staging/platform` | applied, EKS cluster Ready | `kubectl --context aegis-staging-primary get nodes` → ≥1 node Ready |
| `staging/workloads` | applied, observability stack synced | `kubectl -n monitoring get pods` → all Running; kube-prometheus-stack ArgoCD App Synced + Healthy |
| `staging/fis` | applied, experiment template exists | `terraform -chdir=terraform/environments/staging/fis output experiment_template_id` returns an ID |

If any row fails, the drill cannot produce useful signal. Apply missing layers before continuing.

### 1. Verify observability can see the cluster

```bash
kubectl --context aegis-staging-primary port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

In a browser, open `http://localhost:3000`. Log in (admin / retrieve password via `terraform -chdir=terraform/environments/staging/workloads output -raw grafana_admin_password_primary`).

Open **Dashboards → Kubernetes / Compute Resources / Cluster**. You should see CPU + memory series for both cluster nodes. If the series are flat at zero, node-exporter has not reached all nodes — fix before drilling. (Incident 27 is the known offender; post-PR #110 fix, this should be clean.)

### 2. Verify the `NodeNotReady` alert rule is loaded

In Grafana: **Alerting → Alert rules**. Filter by label `drill=fis-primary-outage`. You should see one rule: `NodeNotReady`, state = Normal.

If the rule is missing, the `staging/workloads` layer hasn't applied with the dr-drill alert block yet — re-apply before continuing.

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

```bash
kubectl --context aegis-staging-primary port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Browse to http://localhost:9090/alerts → NodeNotReady should be Inactive
```

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
