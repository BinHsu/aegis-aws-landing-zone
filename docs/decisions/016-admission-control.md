# 016. Admission Control: Kyverno

## Status
Accepted (**amended 2026-04-20**: §Consequences gained a "Layer placement and install path" subsection after Incident 26 — Kyverno moves from `staging/workloads/` as an ArgoCD Application to `staging/platform/` as a `helm_release`. Tool selection is unchanged; only deployment layer + install path changed.)

## Context

Phase 4c adds cluster-level security hardening. One component is admission control — a webhook that intercepts Kubernetes API requests and enforces policies before resources are persisted. Common policies include denying privileged containers, requiring resource limits, and enforcing label conventions.

Two mature projects dominate the Kubernetes admission control space:

- **Kyverno** — policies written in YAML, Kubernetes-native CRDs (`ClusterPolicy`), no new language to learn.
- **OPA Gatekeeper** — policies written in Rego (a purpose-built logic language), backed by the Open Policy Agent engine, wider ecosystem and community adoption.

### Constraints

- **Single operator**: one person writes, reviews, and debugs policies. There is no policy team, no centralized governance, no multi-cluster fleet.
- **Portfolio project**: the policies must be readable by an interviewer scanning the repo. An interviewer who knows Kubernetes should understand a policy without learning a domain-specific language.
- **ArgoCD-managed**: policies should be deployable via GitOps, consistent with the project's ArgoCD-first operational model.
- **Minimal footprint**: the admission controller runs on Karpenter-managed Spot nodes alongside the workload. Memory and CPU overhead matter.

## Decision

**Kyverno**, deployed via `helm_release` in the platform layer. (An earlier version of this ADR deployed Kyverno as an ArgoCD Application in the workloads layer; amended 2026-04-20 — see §Consequences "Layer placement and install path.")

### Rationale

1. **YAML policies are immediately readable.** A Kyverno `ClusterPolicy` looks like a Kubernetes resource with match/exclude selectors and a mutation/validation block. An interviewer (or future-me at 2 AM) can read the policy without knowing Rego. For a single-operator lab where the operator IS the policy author, reviewer, and debugger, removing the Rego learning curve is a net win.

2. **Lower operational surface.** Kyverno is a single Deployment with a webhook. Gatekeeper requires the controller manager, the audit controller, and separate `ConstraintTemplate` + `Constraint` CRDs for each policy type. Kyverno's `ClusterPolicy` CRD is both the template and the instance.

3. **Kubernetes-native generation and mutation.** Kyverno can generate resources (e.g., auto-create a NetworkPolicy when a namespace is created) and mutate requests (e.g., inject default resource limits). Gatekeeper's mutation support is GA but less ergonomic — it requires a separate `Assign` CRD. For this project, mutation is useful for injecting default labels and resource limits into workloads that forget them.

4. **Resource footprint.** Kyverno in standalone mode (no HA) uses ~200 MB RAM. Gatekeeper audit + controller uses ~300 MB. Both are acceptable, but Kyverno is leaner for the features this project needs.

### Policies deployed in Phase 4c

| Policy | Type | Effect |
|---|---|---|
| Deny privileged containers | Validate | Block pods with `securityContext.privileged: true` |
| Deny host namespaces | Validate | Block pods with `hostNetwork`, `hostPID`, or `hostIPC` |
| Require resource limits | Validate | Block pods without `resources.limits.memory` |
| Require common labels | Validate | Block Deployments without `app.kubernetes.io/name` |

These are baseline policies appropriate for a lab. They prevent the most common misconfigurations without blocking legitimate workloads. The `audit` enforcement mode (log violations without blocking) is used initially; `enforce` mode is enabled after verifying no false positives against existing platform pods.

## Alternatives Considered

**OPA Gatekeeper.** Rejected for this project's scope. Gatekeeper is the right choice for organizations with a dedicated platform team, multi-cluster fleet, and existing Rego expertise. Its policy library (`gatekeeper-library`) is larger and more battle-tested. But the Rego learning curve is real — writing and debugging Rego policies is a skill investment that does not transfer to other Kubernetes tools. For a single-operator lab, Kyverno's YAML policies deliver the same security posture with less cognitive overhead.

**Pod Security Standards (PSS) / Pod Security Admission (PSA).** Considered as a complement, not a replacement. PSA is built into Kubernetes 1.25+ and enforces three predefined security profiles (privileged, baseline, restricted) via namespace labels. It is zero-install but coarse-grained — you cannot customize individual rules, add label requirements, or mutate resources. PSA is appropriate as a first layer; Kyverno adds the fine-grained policies PSA cannot express. This project uses Kyverno for both — if PSA namepsace labels are desired later, Kyverno can generate them.

**No admission control.** Rejected. The project claims ISO 27001 Annex A.8 alignment (ADR-005). Admission control is the runtime enforcement layer that complements the review-time checklist in `docs/principles/change-review-discipline.md`. Without it, a `kubectl apply` can bypass every policy the project documents. Even in a single-operator lab, the portfolio value of demonstrating admission control outweighs the small operational cost.

## Consequences

Kyverno's webhook intercepts every pod creation in the cluster. If Kyverno's pods are down, the webhook fails open by default (pod creation succeeds without policy checks). This is the safer failure mode for a lab — a Kyverno outage does not block workload deployment. Production would use `failurePolicy: Fail` to ensure no unvetted pods run.

Kyverno policies are `ClusterPolicy` CRDs (cluster-scoped, not namespace-scoped). Deleting the Kyverno ArgoCD Application cascades to all policies. This is intentional — teardown should be clean.

The `audit` enforcement mode means violations are logged in the Kyverno policy report but pods are not rejected. This is appropriate for initial rollout to avoid breaking existing platform pods (Karpenter, ArgoCD, LBC). After verifying no false positives, switching to `enforce` mode is a one-line change per policy (`validationFailureAction: Enforce`).

### Layer placement and install path (added 2026-04-20 after Incident 26)

Kyverno runs in the `staging/platform/` layer (alongside Karpenter, AWS Load Balancer Controller, and ArgoCD itself), not in `staging/workloads/`. The install path is `helm_release` with `wait = true` (chart default), not an ArgoCD `Application` CRD created via `kubectl_manifest`.

**Reason 1 — failure-mode surface**: admission control is cluster-level infrastructure. If the Kyverno webhook is down or misbehaving, pod admission across the entire cluster is affected. This is the same surface as LBC (if down, no new Ingresses) and Karpenter (if down, no new nodes) — both of which the project already scopes to the platform layer. Observability (kube-prometheus-stack, in the workloads layer) degrades visibility but leaves the cluster running; admission does not.

**Reason 2 — synchronous CRD handoff**: the four `ClusterPolicy` resources above are Terraform-managed (`kubectl_manifest`), and they require the Kyverno CRD (`ClusterPolicy`) to exist in the cluster at apply time. `helm_release` with `wait = true` blocks Terraform until the chart reports Ready, at which point the CRDs are guaranteed present. An ArgoCD Application wrapped in `kubectl_manifest` only guarantees the Application object exists in etcd; chart sync is asynchronous and the CRD can still be absent for 1–3 minutes. That race caused Incident 26 on the first cold apply of the workloads layer after clean teardown.

**What this does NOT change**: tool selection (Kyverno vs Gatekeeper) is unchanged; all four baseline policies are unchanged; `audit` → `enforce` rollout path is unchanged; teardown semantics are unchanged (deleting the Helm release cascades to all policies, same as deleting the ArgoCD Application did).

**What this DOES change**: lifecycle visibility in the ArgoCD UI is lost for Kyverno itself — an operator must now look at `helm_release.kyverno` state / `kubectl -n kyverno get pods` rather than an ArgoCD Application tile. The platform layer's other components (Karpenter, LBC, ArgoCD) share the same tradeoff and it has not caused friction in practice. The ClusterPolicies remain Terraform-managed, so their state is visible via `terraform state list | grep kyverno`.

**Relation to ADR-015**: ADR-015's "Operator Apps via ArgoCD" pattern covers observability (kube-prometheus-stack), where the discovery contract for workload-authored CRDs (ServiceMonitor, PrometheusRule) is the load-bearing reason for ArgoCD-managed lifecycle. Kyverno's policies are platform-authored, not workload-authored — there is no equivalent discovery contract, and the tradeoff tips the other way.
