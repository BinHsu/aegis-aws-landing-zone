# 007. Infrastructure / Application Repository Split

## Status
Accepted

## Context
A GitOps-based multi-account AWS deployment has two fundamentally different kinds of change flowing into the cluster: infrastructure changes (VPC, EKS, IAM, node groups, ingress controllers) and application changes (code, container images, Kubernetes manifests). These two kinds of change have wildly different cadences, blast radii, review requirements, and ownership boundaries. Putting them into one repository — a monorepo — forces every application change through infrastructure review, and every infrastructure change through application awareness. This creates review bottlenecks, ownership confusion, and cognitive overload.

Splitting them into two repositories with strict role separation aligns the repository boundary with the actual ownership boundary. This ADR formalizes the two-repo pattern for `aegis-aws-landing-zone` (the infrastructure repo) and its companion `aegis-core` (the application repo), and specifies the GitOps handoff between them.

## Decision

Two repositories with strict role separation.

`aegis-aws-landing-zone` is the **Pointer** repository. It holds pure infrastructure-as-code: Terraform modules and environments, GitHub Actions workflows, Helm values files for cluster-level installations (ArgoCD itself, cert-manager, Kyverno, Prometheus, Grafana), and the root-level ArgoCD `Application` custom resource. The ArgoCD `Application` is the only place in this repo that references the companion application repo — it points ArgoCD at a specific path in `aegis-core` and tells ArgoCD to sync everything it finds there.

`aegis-core` is the **Payload** repository. It holds the application codebase (a C++ and Go Bazel monorepo), container build configuration via `rules_oci`, and all application-level Kubernetes manifests: Deployments, Services, ConfigMaps, HorizontalPodAutoscalers, NetworkPolicies, and any custom resources consumed by running workloads. Application engineers commit to this repo using their normal PR review process.

ArgoCD running in the EKS cluster continuously monitors the Payload repository's `k8s/` directory and syncs changes automatically. When an application engineer merges a change — for example, increasing replica count or updating an image tag — ArgoCD detects the diff on its next reconciliation cycle and applies it. The Pointer repository is not involved in this flow and does not need a commit.

The contract between the two repositories is minimal and stable. The Pointer repo commits the ArgoCD `Application` resource once per environment (one for `staging`, one for `prod`). The resource specifies: the target Payload repo URL, the target path, the target branch, the target namespace, and the sync policy (automatic for staging, manual for production). After these Applications are created, the Pointer repo never needs to commit again for application changes — the Payload repo is the source of truth for everything ArgoCD syncs.

## Alternatives Considered

**Monorepo containing both infrastructure and application code.** Rejected. Infrastructure changes are high-blast-radius and infrequent — typically weekly to monthly. Application changes are low-blast-radius and frequent — several per day. A monorepo forces every application change through the same PR review and CI pipeline as infrastructure changes, creating unnecessary friction for the high-frequency path and unnecessary visibility for the low-frequency path. Ownership boundaries become unclear: who reviews a change that touches both a Terraform module and a Kubernetes manifest? The monorepo pattern works at companies that have solved this with extensive internal tooling (Google, Meta) but is a trap for smaller projects without that tooling.

**Application Kubernetes manifests in the infrastructure repo, application code in a separate repo.** Rejected. This splits the application across two repos and forces infrastructure engineers to review every Kubernetes deployment change. The reviewers who should approve a replica count change are the application engineers, not the platform engineers — putting the manifests in the infra repo routes them to the wrong reviewers. It also makes the application's rollout cadence dependent on the infrastructure repo's PR queue, which is a throughput cliff.

**Push-based CD from a CI pipeline applying manifests directly.** Rejected. Push-based CD has no GitOps audit trail and makes drift detection harder. When the cluster diverges from the repository state — which always eventually happens, whether from an operator running `kubectl apply` or from a controller mutating a resource — there is no continuous reconciliation. ArgoCD's pull-based model is the opposite: it continuously reconciles cluster state against repository state, so drift is detected and corrected (or reported) without operator intervention.

**Single repo with a strict directory-level review assignment (CODEOWNERS).** Considered. CODEOWNERS can route review attention within a monorepo, which mitigates but does not eliminate the ownership confusion. The release cadence mismatch remains: a high-frequency app change still sits in the same queue as low-frequency infra changes. This is a partial mitigation, not a solution.

## Consequences

Two repositories to maintain, each with its own CI, its own PR review process, and its own release cadence.

Cross-repo changes — a new service requiring both a new IAM role in Pointer and a new Kubernetes manifest in Payload — require coordinated commits in two places. This is genuine friction and is accepted as a trade-off for clean ownership boundaries. The friction is bounded: the number of such cross-cutting changes is small relative to the total change volume.

ArgoCD is the source of truth for application state in the cluster. If an operator directly modifies a Deployment via `kubectl apply`, ArgoCD detects the drift on its next reconciliation cycle and either reverts or reports it, depending on the sync policy configured per environment.

Hiring managers see clean separation of Platform Engineering and Application Engineering roles. The commit history of each repo tells a coherent story — infrastructure-focused in one, application-focused in the other. This reflects how real engineering organizations structure these responsibilities and makes the portfolio more representative of production conditions than a monorepo project would.
