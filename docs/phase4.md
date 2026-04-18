<!-- session-close-review: sub-phase status, aegis-core readiness table, ADR candidate status, cost model -->
# Phase 4 — Workload Readiness, Observability, Cluster Security

## Context

Phase 3c delivered a working EKS cluster with Karpenter, ArgoCD, and the AWS Load Balancer Controller. The platform can be applied from zero and torn down cleanly via GitHub Actions in under 30 minutes. But it is currently a shell: ArgoCD points at `aegis-core`'s `apps/staging/` directory, which is empty. No workloads run, no metrics are collected, no security findings are generated.

Phase 4 closes the gap between "platform exists" and "platform serves a workload and the operator can see what's happening."

The sibling repository [`aegis-core`](https://github.com/BinHsu/aegis-core) has paved part of its side of this boundary. [ADR-0017 (Gateway↔Engine topology)](https://github.com/BinHsu/aegis-core/blob/main/docs/adr/0017-gateway-engine-topology.md) documents the N:N-ready application architecture. [Issue #61](https://github.com/BinHsu/aegis-aws-landing-zone/issues/61) on this repo captures exactly what aegis-core needs from the platform: a Headless Service for the engine pool, an ALB with session affinity for the gateway pool, and gRPC keepalive honoring at the load balancer.

### aegis-core readiness (as of 2026-04-16)

However, aegis-core is **not yet containerized**. Its current state:

| Component | Status | Blocking 4a? |
|---|---|---|
| C++ engine (whisper.cpp transcription) | Working under Bazel | Not directly — needs OCI packaging |
| Go gateway (gRPC client → engine) | Health passthrough working | Same |
| Frontend (React + Vite) | Scaffolded, audio capture done | Same |
| WebRTC / WebSocket / session registry | Phase 2 — not started | Yes — gateway can't serve real traffic yet |
| `rules_oci` / Dockerfile | Phase 3/4 in aegis-core roadmap | **Yes — no container image to deploy** |
| K8s manifests (Deployment, Service, Ingress) | Do not exist | **Yes — nothing for ArgoCD to sync** |
| CI → ECR push pipeline | Does not exist | **Yes — no automated delivery** |

**Implication for Phase 4 ordering**: deploying a real workload (original 4a) is gated on aegis-core shipping OCI packaging + K8s manifests. This is aegis-core's work, not landing-zone's. The ECR repository is already live and waiting ([#54 platform contract](https://github.com/BinHsu/aegis-aws-landing-zone/issues/54), [#11 aegis-core notification](https://github.com/BinHsu/aegis-core/issues/11#issuecomment-4257309501)).

**Adapted strategy**: split 4a into two halves. **4a' (docking station)** builds the platform-side infrastructure that does not depend on aegis-core — namespace, IRSA skeleton, NetworkPolicy base, OIDC trust verification. **4a'' (workload deployment)** wires up the actual pods, Services, and Ingress once aegis-core delivers OCI images and manifests. Meanwhile, **4b (observability) and 4c (cluster security) can proceed independently** — they observe and protect the cluster itself, not just the workload.

## Goals

1. **Deploy a real workload** — aegis-core's gateway + engine running on the platform, reachable via ALB, with ArgoCD managing the lifecycle. This is the first time the landing zone *does something* beyond bootstrapping itself.
2. **Observe the workload** — Prometheus scraping cluster and app metrics, Grafana rendering dashboards, EKS control plane logs flowing to CloudWatch. An operator debugging at 2 AM can see what happened without guessing.
3. **Detect threats at the cluster level** — GuardDuty EKS Runtime Monitoring, basic admission policies (OPA Gatekeeper or Kyverno), VPC Flow Logs to the centralized log archive.
4. **Maintain cost discipline** — everything new must have a known hourly cost and tear down cleanly. The $5–10/session budget does not change.

## Sub-phases

### Phase 4a' — Docking station (platform-side, no aegis-core dependency)

**What this delivers**: the platform-side infrastructure that aegis-core can "dock" into when it ships OCI images. Does NOT require aegis-core to have containers or manifests — all work is on the landing-zone side.

**Terraform / K8s resources**:

| Resource | Purpose | Layer | Depends on aegis-core? |
|---|---|---|---|
| Kubernetes Namespace `aegis` | Workload isolation | `staging/workloads` or ArgoCD-managed | No |
| IRSA role skeleton for engine | Least-privilege pod identity (trust policy ready, no pod yet) | `staging/workloads` | No |
| NetworkPolicy base (default-deny in `aegis` ns) | Security posture before workload arrives | `staging/workloads` | No |
| ECR repo | Already live in `staging/bootstrap` | — | No (done) |
| OIDC trust for aegis-core CI → ECR push | Verify `github-actions-terraform` trust policy covers aegis-core's OIDC subject | `staging/bootstrap` | Needs aegis-core CI subject pattern |

**Cost increment**: $0 (namespace + IRSA + NetworkPolicy are Kubernetes API objects, no AWS billing).

---

### Phase 4a'' — Workload deployment (gates on aegis-core OCI readiness)

**What this delivers**: aegis-core's gateway + engine pods running on Karpenter-managed Spot nodes, fronted by an ALB, with ArgoCD handling sync. The first time a viewer can open a URL and see the product.

**Blocked until aegis-core delivers**:
1. OCI images for gateway + engine (via `rules_oci` or Dockerfile) pushed to ECR
2. K8s manifests under `apps/staging/` (Deployment, Service, Ingress) for ArgoCD to sync
3. CI pipeline that builds + pushes images on merge to aegis-core main

**Resources (landing-zone side, after aegis-core delivers)**:

| Resource | Purpose | Layer |
|---|---|---|
| Headless Service (`clusterIP: None`) for engine pool | DNS-based gRPC client-side load balancing (aegis-core ADR-0017) | aegis-core manifests |
| Ingress / ALB for gateway pool | HTTP(S) entry point with session affinity | aegis-core manifests + LBC annotation |
| NetworkPolicy allow-rules | gateway↔engine, gateway↔ALB | aegis-core manifests |

**ALB session affinity decision** (ADR candidate — see §ADR candidates):

aegis-core's ADR-0004 requires session-level affinity at the gateway tier. Two mechanisms are available via the AWS Load Balancer Controller:

- **ALB target group stickiness** (`alb.ingress.kubernetes.io/target-group-attributes: stickiness.enabled=true,stickiness.type=app_cookie`) — simplest, but ALB stickiness uses cookies and has a 1-day minimum duration.
- **NLB with client IP affinity** — lower latency for gRPC, but no L7 path routing for future multi-service ingress.

Neither is obvious without measuring. The ADR should evaluate both against the specific session lifecycle of aegis-core (minutes to hours, not days). **This ADR can be written during 4a' even before aegis-core ships containers** — the decision is about platform topology, not application code.

**Cross-repo coordination**:
- Update [#54 (platform surface contract)](https://github.com/BinHsu/aegis-aws-landing-zone/issues/54) with the new namespace, IRSA role, and any new CRDs. ECR section already added (2026-04-16).
- Respond to [#61 (FYI: Gateway↔Engine topology)](https://github.com/BinHsu/aegis-aws-landing-zone/issues/61) with the chosen ALB affinity mechanism once the ADR is written.
- If aegis-core CI uses an OIDC subject pattern not covered by the current trust policy, open a `cross-repo/blocking` issue.

**Cost increment**: near-zero incremental (pods run on existing Karpenter Spot nodes; ALB already created by LBC if an Ingress resource exists — ~$0.02/hour for the ALB + LCU charges at lab traffic).

---

### Phase 4b — Observability stack

**What this delivers**: Prometheus + Grafana on the cluster, scraping both platform and workload metrics. An operator can see node utilization, pod health, Karpenter provisioning decisions, and aegis-core application metrics from a single Grafana URL.

**Approach**: `kube-prometheus-stack` Helm chart via ArgoCD (app-of-apps pattern). This is the community standard for single-cluster observability — Prometheus Operator, Grafana, node-exporter, kube-state-metrics, and default dashboards in one chart.

**Resources**:

| Resource | Purpose | Notes |
|---|---|---|
| `kube-prometheus-stack` Helm release | Prometheus + Grafana + dashboards | ArgoCD-managed via app-of-apps |
| Grafana Ingress (ALB) | Browser access to dashboards | ACM cert, same domain pattern as Phase 3 |
| PersistentVolumeClaim for Prometheus | Retain metrics across pod restarts | gp3 EBS, 20 GB, Karpenter-managed node |
| ServiceMonitor CRDs | Scrape targets for aegis-core pods | aegis-core manifests expose `/metrics` |
| CloudWatch log group retention | EKS control plane logs (already on) | Verify 365-day retention from Phase 3 |

**VPC Flow Logs** (AWS-side, not K8s):

| Resource | Purpose | Layer |
|---|---|---|
| VPC Flow Log → S3 in `aegis-logarchive` | Network audit trail | `staging/network` |
| S3 lifecycle rule (90-day transition to IA) | Cost control on flow log storage | `logarchive/bootstrap` |

**ADR candidate**: observability tooling — why kube-prometheus-stack over CloudWatch Container Insights, Datadog, or Grafana Cloud. Cost, portability, and operational surface are the three axes.

**kubent / pluto CI integration**: wire into `checkov.yml` or a new workflow step. `pluto detect-files -d k8s-manifests/` runs in <5 seconds and catches deprecated API usage before merge. Already recommended in [`docs/principles/change-review-discipline.md`](principles/change-review-discipline.md); Phase 4b is when it becomes real.

**Cost increment**: ~$1–2/session extra (Prometheus + Grafana pods need ~1 vCPU + 2 GB RAM on Spot; 20 GB gp3 EBS = $0.08/GB/month = $1.60/month if persistent). VPC Flow Logs: negligible at lab traffic volume (~$0.50/month).

---

### Phase 4c — Cluster security hardening

**What this delivers**: threat detection at the cluster level (not just the org level, which Control Tower already provides). A complement to the SCPs and IAM policies that Phase 1 established.

**Resources**:

| Resource | Purpose | Layer |
|---|---|---|
| GuardDuty EKS Runtime Monitoring | Container-level threat detection (crypto mining, reverse shell, privilege escalation) | `staging/platform` or `security/guardduty` |
| GuardDuty EKS Audit Log Monitoring | API audit trail anomaly detection | Same |
| Kyverno or OPA Gatekeeper | Admission policies (deny privileged, require labels, enforce resource limits) | ArgoCD-managed |
| `apiserver_requested_deprecated_apis` alert | Prometheus alert rule on deprecated API usage (see principles doc §3.4) | kube-prometheus-stack values |

**Scope discipline**: Phase 4c is the *minimum credible* cluster security for a portfolio project. It is NOT:
- A full SOC 2 control set (explicitly NOT claimed in interview-notes §4)
- Security Hub aggregation (Phase 4c may enable it, but the interesting part is GuardDuty findings, not the dashboard)
- AWS Config conformance packs (deferred — high noise-to-signal for a single-cluster lab)

**ADR candidate**: Kyverno vs OPA Gatekeeper. Kyverno is simpler (YAML policies, no Rego). Gatekeeper has a larger ecosystem. The ADR should evaluate against this project's single-operator constraint.

**Cost increment**: GuardDuty EKS Runtime Monitoring = ~$1.50/vCPU/month for runtime agent. With 4 vCPU Karpenter cap → ~$6/month if always-on, but session-based → ~$0.25/session. EKS Audit Log Monitoring: ~$1/month.

---

## Cost model (Phase 4 complete, per session)

| Component | Hourly | Per 4h session |
|---|---|---|
| Phase 3 baseline (EKS + NAT + Karpenter Fargate) | ~$1.20 | ~$4.80 |
| Phase 4a ALB (workload ingress) | ~$0.02 | ~$0.08 |
| Phase 4b Prometheus + Grafana (Spot node capacity) | ~$0.10 | ~$0.40 |
| Phase 4b Flow Logs | negligible | negligible |
| Phase 4c GuardDuty | ~$0.06 | ~$0.25 |
| **Total** | **~$1.38** | **~$5.53** |

Within the $5–10/session budget. No change to the teardown requirement — `gh workflow run terraform-teardown-workload.yml` at session end remains mandatory.

**Persistent costs** (running even when torn down):
- EBS volume for Prometheus (if not destroyed): $1.60/month. Consider destroying on teardown and accepting metric loss between sessions; lab data has no retention requirement.
- Flow Logs S3 storage: <$0.50/month.

---

## ADR candidates

| # | Topic | Trigger |
|---|---|---|
| 014 | ALB session affinity for gRPC workloads | Phase 4a — cookie vs client-IP, ALB vs NLB for gRPC |
| 015 | Observability tooling: kube-prometheus-stack | Phase 4b — why not Container Insights or managed Grafana |
| 016 | Admission control: Kyverno vs OPA Gatekeeper | Phase 4c — single-operator simplicity vs ecosystem breadth |
| 017 | Workload namespace and RBAC model | Phase 4a — single namespace vs per-component, ArgoCD-managed vs Terraform-managed |

ADR numbering continues from 013 (current last). Write each ADR BEFORE implementing its topic — [CLAUDE.md](../CLAUDE.md) requires ADR-first for significant design choices.

---

## Cross-repo coordination

| Issue | Repo | Action in Phase 4 |
|---|---|---|
| [#54 — Platform surface contract](https://github.com/BinHsu/aegis-aws-landing-zone/issues/54) | landing-zone | Update body after each sub-phase ships |
| [#61 — Gateway↔Engine topology FYI](https://github.com/BinHsu/aegis-aws-landing-zone/issues/61) | landing-zone | Reply with chosen ALB affinity mechanism after ADR-014 |
| [#11 — Requirements from landing-zone](https://github.com/BinHsu/aegis-core/issues/11) | aegis-core | Check at session start; respond to any new asks |

ECR availability already communicated to aegis-core (2026-04-16): [#54 updated with Container Registry section](https://github.com/BinHsu/aegis-aws-landing-zone/issues/54), [#11 comment with push instructions](https://github.com/BinHsu/aegis-core/issues/11#issuecomment-4257309501). If aegis-core CI needs a trust policy update (different OIDC subject pattern), it should open a `cross-repo/blocking` issue on this repo.

---

## Prerequisites (before starting Phase 4a)

1. `aws sso login --sso-session aegis` (8h token)
2. `gh workflow run terraform-apply-workload.yml -f env=staging` → approve → wait ~20 min (rebuilds VPC + NAT + EKS + Karpenter + LBC + ArgoCD)
3. Verify platform per [Runbook 003](runbooks/003-platform-first-verification.md) (5 min)
4. `gh issue list -l cross-repo -R BinHsu/aegis-aws-landing-zone` + `gh issue list -l cross-repo -R BinHsu/aegis-core` — check for `cross-repo/blocking` (CLAUDE.md rule)

---

## What is NOT Phase 4

Explicit boundary so scope creep has a name:

- **cert-manager / service mesh mTLS** → Phase 5 (per interview-notes §5, ADR-013 "ACM over cert-manager" rationale still holds until in-cluster TLS termination is needed)
- **EKS Pod Identity migration** → Phase 5 (IRSA works today; migration is a version-hygiene task, not a capability gap)
- **Multi-cluster** → not planned (single-operator lab; federation / fleet management is beyond scope)
- **DR failover testing** → not planned (eu-west-1 exists in Control Tower; testing DR requires a second cluster, which doubles cost)
- **Production deployment** → this landing zone is not production. Phase 4 demonstrates patterns that transfer to production; it does not claim to be production. ([interview-notes §4](interview-notes.md) makes this explicit.)

---

## Suggested execution order

Two parallel tracks. The landing-zone track runs independently; the workload track gates on aegis-core.

```
LANDING-ZONE TRACK (no aegis-core dependency)
  │
  ├── Phase 4a' (docking station)
  │     ├── ADR-014 (ALB affinity — platform topology, writeable now)
  │     ├── ADR-017 (namespace model)
  │     ├── Terraform: staging/workloads (namespace, IRSA skeleton, NetworkPolicy base)
  │     ├── Verify OIDC trust covers aegis-core CI subject
  │     └── Update #54 platform contract
  │
  ├── Phase 4b (observability) — can start immediately after 4a'
  │     ├── ADR-015 (kube-prometheus-stack rationale)
  │     ├── ArgoCD app: kube-prometheus-stack Helm
  │     ├── Grafana Ingress + ACM cert
  │     ├── VPC Flow Logs (Terraform: staging/network)
  │     ├── kubent / pluto CI step
  │     └── Verify: Grafana dashboards load, cluster metrics present
  │
  └── Phase 4c (cluster security) — can overlap with 4b
        ├── ADR-016 (Kyverno vs Gatekeeper)
        ├── GuardDuty EKS (Terraform: staging/platform or security/)
        ├── Admission policies (ArgoCD-managed Kyverno/Gatekeeper)
        ├── deprecated-API Prometheus alert (requires 4b Prometheus)
        └── Verify: GuardDuty finding for test event, admission policy blocks privileged pod

WORKLOAD TRACK (gates on aegis-core)
  │
  │  ⏳ Wait: aegis-core ships OCI packaging + K8s manifests + CI→ECR push
  │
  └── Phase 4a'' (workload deployment)
        ├── aegis-core pushes first image to ECR
        ├── aegis-core commits manifests under apps/staging/
        ├── ArgoCD syncs → pods run → ALB routes traffic
        ├── Verify: curl → ALB → gateway → engine → transcription response
        ├── Workload metrics appear in Grafana (if 4b already done)
        └── Update #54 platform contract with workload-specific surface
```

**Key insight**: the original spec assumed 4a was the critical path blocking everything. In practice, **4b and 4c are the highest-value work the landing-zone can do right now** — they demonstrate observability and security skills in the portfolio without waiting for aegis-core. 4a'' completes whenever aegis-core is ready; the platform will be waiting.

---

*Written: 2026-04-16. Revised same day to reflect aegis-core readiness assessment — OCI packaging not yet available; spec split into two parallel tracks.*

*Updated: 2026-04-17. Landing-zone track complete: 4a' (PR #67), 4b (PR #67), 4c (PR #68). ADRs 014–017 all shipped. Flow logs bucket moved to bootstrap (PR #69). Least-privilege aegis-core CI roles landed (PR #74, per #72). Remaining: 4a'' gates on aegis-core OCI packaging.*
