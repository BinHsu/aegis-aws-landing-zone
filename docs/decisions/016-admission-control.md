# 016. Admission Control: Kyverno

## Status
Accepted

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

**Kyverno**, deployed as an ArgoCD Application.

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
