<!-- session-close-review: version tracking table §4 matches actual deployed versions -->
# Change Review Discipline

> **Scope**: platform-level change review — cluster components, EKS version upgrades, CNI/CSI, ingress controller, IAM surfaces, GitHub Actions workflow edits, Terraform provider / module bumps, SCP changes.
>
> **Not in scope**: application-manifest changes (Deployment/Service/HPA version bumps, Helm chart updates of app charts, app rollback procedures). Those belong to [`aegis-core`](https://github.com/BinHsu/aegis-core), not here. The ownership split mirrors the repository split documented in [ADR-007](../decisions/007-infra-app-repository-split.md).

This document is an **operational discipline doc**, not an ADR. It captures *how* platform changes are reviewed on this repo — the mental checklist before a PR opens and the automated guardrails before it merges. ADRs record *what* was decided; this doc records *how to decide well*.

---

## 1. Why this matters more than usual for a platform repo

A platform-level change has two qualities most application changes don't:

1. **Blast radius is shared.** A broken ingress-controller-policy change takes down every service in the cluster; a broken Kubernetes API version assumption takes down every controller that depends on that API. The surface that *looks* like one file change is often the entry point to every workload on the cluster.
2. **Deprecations arrive with long fuses.** Kubernetes deprecates APIs v+3 releases out; AWS deprecates resource attributes across provider major bumps; GitHub Actions deprecates syntax silently via Node version changes. The time between "noticed" and "broken" is long enough that the fix stops feeling urgent — which is exactly when it becomes a production surprise.

Specific deprecations already on the horizon as of 2026:

- **Ingress NGINX** retired 2026-03-24 (upstream EOL). Our platform avoids this by using AWS Load Balancer Controller instead — see [ADR-013 §Alternatives Considered](../decisions/013-eks-architecture.md). This is a concrete "conservative-by-design" decision that paid off without special effort.
- **`discovery.k8s.io/v1.Endpoints`** deprecated in Kubernetes v1.33 (use `EndpointSlices`).
- **`externalIPs` in `Service` type** deprecated v1.36.
- **AWS provider v5 → v6** (major bump) — handled 2026-04-15; baseline apply succeeded across all six Terraservices. See Incident 24 aftermath for the Dependabot rebase sequencing.

If any of the above surprised a team, it's because their discipline wasn't continuous. The cost of the discipline is lower than the cost of the surprise.

---

## 2. The 5-step checklist (applies to every platform PR)

Before merging a platform change — whether a Terraform diff, a workflow edit, or a Helm value bump — the author (and reviewer) must answer all five. If any answer is "I don't know," the PR is not ready.

### 2.1 Blast radius
*If this change misbehaves, what is the smallest set of systems affected? The largest?*

- "Only this one NodePool" — low blast.
- "Every pod on the cluster" — high blast (e.g., CNI, kube-proxy replacement, admission webhook).
- "Every workload account using the shared VPC" — highest blast.

**Rule**: changes with cluster-wide or org-wide blast must include a rollback plan in the PR description, not just in the reviewer's head.

### 2.2 Dependency assumptions
*What is this change assuming about the state of other components?*

- "Karpenter NodePool assumes Karpenter controller is running" — trivially true but worth naming.
- "This IAM policy assumes the IRSA OIDC provider was already registered" — subtle; forgetting it caused Incident 11's family of delays.
- "This Terraform data source assumes the remote state file is reachable from this principal" — caused Incident 5 (cross-account `kms:Decrypt` on `aws/s3`).

**Rule**: list the non-obvious dependencies explicitly. "Obvious to me now" becomes "invisible in six months."

### 2.3 Deprecation status of what's being touched
*Is the API / resource / action version you're using still supported? For how long?*

- **Terraform provider attributes**: check the provider's upgrade guide (e.g., [AWS provider v6 upgrade guide](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/guides/version-6-upgrade)).
- **Kubernetes APIs**: run `kubent` (see §3.1) against the cluster before the change; run `pluto` on the PR's Helm values and rendered YAML.
- **GitHub Actions**: the `node20` → `node24` deprecation is an ongoing treadmill. Check the action's repo for "uses Node.js 20" warnings in its README or latest release notes.
- **AWS service APIs**: check the service's deprecation notices (AWS generally deprecates with long fuses).

**Rule**: if the thing you're touching is deprecated, the PR must either (a) migrate to the replacement, or (b) explicitly justify staying on the deprecated path with an end-of-life date.

### 2.4 Rollback plan
*If this change breaks something we didn't catch in review, how do we revert? How long does revert take?*

- **Fastest**: `git revert` + CI apply. Viable when the change is a single commit and the state file is consistent with the code (most baseline changes).
- **Medium**: revert the commit, then run a narrower apply (e.g., `terraform apply -target=...`). Needed when partial application has left state + AWS diverged.
- **Slowest**: destroy + recreate the affected layer. Needed for stuck state locks or orphan resources (see Incidents 20, 22).

**Rule**: "we'll figure it out" is not a rollback plan. Put the command line in the PR description.

### 2.5 2 AM readability
*If the on-call (including future-me) is debugging this at 2 AM, will the code make sense?*

- Variable names descriptive enough to re-parse in a coffee-deprived brain?
- Comments where the *why* is non-obvious and not captured elsewhere?
- Resource names that collide with AWS's auto-generated ones? (Incident 20: EKS's auto-created cluster SG looks like a Terraform-managed one until it's orphaning your VPC.)
- ADR reference in the PR description for the decision this change embodies?

**Rule**: the code you ship is the code someone else will read under stress. Optimize for that reader.

---

## 3. Automated deprecation detection

Human checklists degrade. Automate the detections that cost nothing to run.

### 3.1 `kubent` — Kube-No-Trouble

Scans a running cluster for resources using deprecated API versions. Runs against live state, so it catches what's *actually* there, not what the manifests *claim*.

**CI integration** (recommended, not yet implemented):

```yaml
- name: kubent
  run: |
    kubectl apply -f - <<< "$(curl -sL https://raw.githubusercontent.com/doitintl/kube-no-trouble/master/installation/install.sh | sh)"
    kubent --context $CLUSTER --exit-error-on-issue
```

**Local use** (today):

```bash
# After aws eks update-kubeconfig, per runbook 002
kubent
```

### 3.2 `pluto` — static scanner

Scans Helm charts, `kustomize` output, or raw YAML for deprecated API versions. Catches before apply; complementary to `kubent` (which catches after).

**CI integration** (recommended):

```yaml
- name: pluto
  run: |
    pluto detect-files -d k8s-manifests/ --target-versions k8s=v1.32.0
```

### 3.3 Terraform provider upgrade diffing

When a Dependabot PR bumps a provider across a major version boundary (v5 → v6), the `Terraform Plan` PR comment is the artifact. Expected signals:

- **No resource changes** in plan output → clean major bump (AWS provider v6 on 2026-04-15 had this shape for all six Terraservices).
- **Resource changes** in plan output → read each change carefully against the provider's upgrade guide. Likely renames / default changes, not bugs.
- **Plan errors** → the provider's stricter validation in the new major version caught an existing misconfiguration. Fix the config, don't pin to old provider.

### 3.4 Kubernetes API server deprecated-api metrics

The API server emits `apiserver_requested_deprecated_apis` when a client uses a deprecated API. In a Phase 4+ observability stack, alert on any non-zero value. Today this metric is collected (EKS control plane logs go to CloudWatch) but not alerted on — tracked as a Phase 4 observability task.

---

## 4. Platform-level version tracking

The living inventory of what's deployed and when it expires. Maintained in this document as a lightweight alternative to a CMDB until the cluster count justifies something heavier.

> **Update rule**: whenever a platform component version changes (Terraform apply merged to main, Helm chart bumped, EKS upgrade performed), update this table in the same PR. Out-of-date version tracking is worse than no tracking.

| Component | Version (as of 2026-04-16) | Upstream EOL / deprecation | Our migration trigger | ADR |
|---|---|---|---|---|
| Terraform CLI | 1.14.8 | — | — | [ADR-003](../decisions/003-terraform-backend-bootstrap.md) |
| AWS provider | 5.100.0 | v5 EOL TBD | Dependabot PR when v6 releases | — |
| EKS Kubernetes | 1.32 | ~14 months from GA | Three releases before EOL | [ADR-013](../decisions/013-eks-architecture.md) |
| Karpenter | v1.0.8 | v0.x deprecated; on v1 | Hold on v1.x until v2 stabilizes | [ADR-013](../decisions/013-eks-architecture.md) |
| AWS Load Balancer Controller | v2.8.2 | — | Bump with EKS minor | [ADR-013](../decisions/013-eks-architecture.md) |
| ArgoCD | 7.6.12 (chart) | — | Quarterly review | [ADR-013](../decisions/013-eks-architecture.md) |
| kube-prometheus-stack | 72.6.2 (chart) | — | Dependabot or manual review | [ADR-015](../decisions/015-observability-tooling.md) |
| Kyverno | 3.4.1 (chart) | — | Dependabot or manual review | [ADR-016](../decisions/016-admission-control.md) |
| cert-manager | Not deployed | — | Phase 5 (service mesh + per-pod TLS) | — |

---

## 5. How this connects to existing discipline

- [**ADR-005 — ISO 27001 Annex A.8 Change Management**](../decisions/005-compliance-framework-iso-27001.md): the formal framework this doc is the *executable form* of. ADR-005 says "we do change management." This doc says "here is the checklist, here are the tools."
- [**ADR-008 — Control Tower hybrid**](../decisions/008-landing-zone-tooling-control-tower-hybrid.md): tooling choices that pre-emptively reduce deprecation risk by staying on managed surfaces (Control Tower instead of hand-rolled Organizations wiring) where the cost-benefit favors them.
- **Future Kyverno / admission-control ADR** (not yet written): admission webhooks are the *runtime* enforcement of the checks this doc runs at *review time*. Once Phase 4 observability is in place, admission-time deprecation blocks are the natural next layer.
- [**CLAUDE.md**](../../CLAUDE.md): the operational rules that live at the project root. This doc defers to CLAUDE.md on anything it restates.

---

## 6. Boundary: what this document does NOT cover

- **Application code changes**: see [`aegis-core`'s change discipline](https://github.com/BinHsu/aegis-core) when that repo documents its own (platform ≠ app).
- **Hot-fixing production directly**: this repo has no production yet. When production is live, a "break-glass change" path will need its own runbook — not this doc.
- **Dependency pinning strategy**: covered by Dependabot config (`.github/dependabot.yml`). This doc is about reviewing what Dependabot proposes, not about whether Dependabot should propose it.
- **Incident response**: see [`docs/incidents.md`](../incidents.md) and the per-incident postmortems. This doc is preventive; incidents are post-hoc.

---

*Last updated: 2026-04-15 — initial doc, triggered by the backlog item flagged during Phase 3c rollout. Incident 24 (Terraform state-lock stampede under Dependabot bulk rebase) is the first case study that exercises step 2.4 (rollback plan) and 3.3 (provider upgrade diffing) from this checklist retroactively.*
