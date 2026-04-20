<!-- session-close-review: GuardDuty EKS Runtime agent health status (still degraded / partially fixed / fixed) + addon management path (GuardDuty-managed vs self-managed aws_eks_addon) -->
# 010. GuardDuty EKS Runtime agent — Fargate compatibility + CrashLoopBackOff

## Current state

`staging/workloads/modules/eks-workloads/guardduty.tf` enables GuardDuty EKS Runtime Monitoring with AWS-managed addon install:

```hcl
resource "aws_guardduty_detector_feature" "eks_runtime" {
  name   = "EKS_RUNTIME_MONITORING"
  status = "ENABLED"
  additional_configuration {
    name   = "EKS_ADDON_MANAGEMENT"
    status = "ENABLED"
  }
}
```

AWS installs the `aws-guardduty-agent` EKS addon as a DaemonSet in the `amazon-guardduty` namespace. Post first cold apply (Session C, 2026-04-20) the DaemonSet pods showed:

```
amazon-guardduty   aws-guardduty-agent-k2xn6   0/1   CrashLoopBackOff   6   (on EC2 node)
amazon-guardduty   aws-guardduty-agent-tm2zz   0/1   Pending            0   (on Fargate node)
```

Same split on both primary and slave_1 clusters.

## Gap / risk

| Surface | Status | Impact |
|---|---|---|
| AWS-side feature enable | ✅ ENABLED (GuardDuty reports the feature active) | Billing proceeds; findings are *expected* but none generated because agent is non-functional |
| In-cluster DaemonSet health | ❌ No pod reaches Running | Runtime threat detection is effectively OFF despite being configured |
| EKS Audit Log Monitoring | ✅ Unaffected (control-plane-level, no agent needed) | API-level threat detection continues to work |

The project claims runtime monitoring in ADR-016 and docs/interview-notes.md §Security posture. That claim is partially false today: the AWS-side switch is on but no pod ever exports telemetry.

## Threat addressed

The original threat model for EKS Runtime Monitoring covers:
- Container escape attempts via privileged syscalls
- Crypto-mining binaries in containers
- Reverse-shell patterns in pod exec
- DNS exfiltration patterns
- File-integrity changes on agent-instrumented nodes

None of these are detected today. The residual detection surface is EKS Audit Log Monitoring (control-plane API calls) only.

## Root cause candidates (not fully diagnosed)

In decreasing likelihood (per Incident 28):

1. **Fargate scheduling**: the DaemonSet pod tries to schedule on Fargate nodes. Fargate forbids host-level access (eBPF programs, `/sys`, `/proc`) that the runtime agent requires — manifests as `Pending` (no Fargate profile matches `amazon-guardduty` namespace) on the Fargate-land pod.
2. **EC2-side config**: IAM (Karpenter node role lacks a GuardDuty runtime permission), AMI (kernel version incompatible with the agent's eBPF program), or agent config (some addon configuration_values not auto-populated). Manifests as `CrashLoopBackOff`.
3. **Both 1 + 2**: which is what the split signature suggests.

Live `kubectl describe pod` + `kubectl logs --previous` output would discriminate between these — that didn't happen in-session because teardown was prioritized over diagnosis (cost cap). The output is NOT in `gh run view` — it was a local kubectl session that ended with the cluster.

## Scope

**Runtime agent health only.** Does not touch EKS_AUDIT_LOGS or the `aws_guardduty_detector` resource itself.

## Target design

Three design points, independent axes:

### 1. Addon management path

- **Current**: AWS-managed via `EKS_ADDON_MANAGEMENT=ENABLED` on the detector feature. Addon install is entirely in AWS's hands; we cannot pass `configuration_values`.
- **Target**: self-managed via explicit `aws_eks_addon "aws_guardduty_agent"` resource. `configuration_values` can carry `nodeAgent.affinity` (Fargate exclusion) and any IAM / resource tuning the root cause investigation determines is needed. The detector feature drops to `EKS_ADDON_MANAGEMENT=DISABLED` (or the inner block is removed entirely).

Switching modes is a one-way door in terms of addon ownership but reversible per-cluster by re-enabling `EKS_ADDON_MANAGEMENT` (AWS takes over again).

### 2. Fargate exclusion

Same principle as Incident 27's node-exporter fix: nodeAffinity `NotIn [fargate]` on `eks.amazonaws.com/compute-type`. Applied via `configuration_values`:

```json
{
  "nodeAgent": {
    "affinity": {
      "nodeAffinity": {
        "requiredDuringSchedulingIgnoredDuringExecution": {
          "nodeSelectorTerms": [{
            "matchExpressions": [{
              "key": "eks.amazonaws.com/compute-type",
              "operator": "NotIn",
              "values": ["fargate"]
            }]
          }]
        }
      }
    }
  }
}
```

The exact config key (`nodeAgent.affinity` vs `daemonSet.affinity` vs `affinity`) depends on the addon version's schema — look up `aws eks describe-addon-configuration --addon-name aws-guardduty-agent --addon-version <v>` to confirm before coding.

### 3. EC2 CrashLoopBackOff fix

Dependent on live diagnosis. Possible axes:
- IAM: add `guardduty:GetDetector` / `guardduty:CreateRuntimeDetection` to the Karpenter node role.
- AMI: bump EKS node AMI family / Kubernetes minor version.
- Agent config: pass `configuration_values.resources.limits` if the default is OOM-ing.

Cannot be finalized from static analysis.

## Prerequisites

- Live EKS cluster with the current buggy deployment so `kubectl describe pod` / `kubectl logs --previous` can run. A portfolio-only cold apply window (~20 min + ~\$0.50) is sufficient.
- `aws eks describe-addon-configuration --addon-name aws-guardduty-agent` output to confirm the addon version's supported `configuration_values` schema.

## Reversibility

Fully reversible. Going back to `EKS_ADDON_MANAGEMENT=ENABLED` + removing the explicit `aws_eks_addon` returns the cluster to current broken state (no worse than today).

## Cost estimate

| Component | Delta |
|---|---|
| Runtime agent billing (already active) | $0 change — GuardDuty bills per vCPU/hour regardless of agent health |
| Terraform refactor | ~1 hour |
| Cold-apply verification cycle | ~\$0.50 (if done standalone), $0 (if bundled into another Session) |

## Operational burden

Slightly higher once self-managed: addon version bumps become a Terraform concern (update `version` attribute on `aws_eks_addon`). AWS-managed mode handled bumps invisibly. Acceptable trade.

## Validation plan

Per-cluster after next cold apply of the platform + workloads layers:

1. `kubectl -n amazon-guardduty get pods -o wide` — expected: one pod per EC2 node, zero pods on Fargate, all Running.
2. `kubectl -n amazon-guardduty logs <pod>` — expected: no error stream; agent reports "connected to GuardDuty control plane."
3. `aws guardduty get-member --detector-id <id>` — expected: `runtimeMonitoring.status = ENABLED`, no degraded reason.
4. Synthetic runtime signal: `kubectl run test-shell --rm -it --image=busybox -- sh -c "nc -l -p 9999"` in a workload namespace — GuardDuty should generate a `RuntimeMonitoring:...` finding within ~15 minutes (matches `finding_publishing_frequency`).

## Portfolio angle

1. **Enabled ≠ Effective**: the write-up itself demonstrates the discipline of noticing "switch is on but pods are broken" — an audit signal most ops teams miss.
2. **Blast-radius-aware fix**: self-managed addon gives control of the Fargate-exclusion knob without rewriting our whole compute strategy. Explicit tradeoff documented.
3. **Cross-cutting Fargate lesson**: paired with Incident 27 (node-exporter same issue), this is a concrete instance of "Any DaemonSet in the cluster must be configured to skip Fargate nodes" — should land as a one-line addition to ADR-013 (eks-architecture) Consequences.

## Deferred / out of scope

- **Multi-region GuardDuty** findings aggregation. Phase 4d observability concern.
- **Automated remediation**: GuardDuty finding → EventBridge → Lambda response. Lab-tier wants findings visible, not auto-remediated.

## Lab status

Not started. Incident 27 fix (PR #110 pending — node-exporter Fargate exclusion) is the known-good template for the Fargate exclusion half of this entry. The CrashLoopBackOff half is blocked on live diagnosis.
