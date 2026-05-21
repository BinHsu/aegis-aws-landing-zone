# 007. Infrastructure / Application Repository Split

## Status
Accepted

## Context
A GitOps-based multi-account AWS deployment carries several fundamentally different kinds of change: account-fabric changes (Organizations, OUs, SCPs, Identity Center, IPAM, the GitHub OIDC trust surface), cluster and platform changes (the EKS cluster, ArgoCD, the cluster add-ons, the GitOps deploy manifests), and application changes (application code, container images). These have wildly different cadences, blast radii, review requirements, and ownership boundaries. Putting them into one repository — a monorepo — forces every application change through infrastructure review, and every infrastructure change through application awareness. This creates review bottlenecks, ownership confusion, and cognitive overload.

Splitting them into separate repositories with strict role separation aligns the repository boundary with the actual ownership boundary. This ADR formalizes the tier model and the GitOps handoff between the tiers.

## Decision

Three repositories, organized as a tier model. Each tier owns one boundary and depends only downward.

**Landing Zone tier — `aegis-aws-landing-zone` (this repository).** The AWS account fabric: AWS Organizations and OUs, Service Control Policies, AWS Identity Center, account bootstrap and vending, organization-wide IPAM, the centralized security and audit baseline, and the GitHub OIDC identity provider. It is pure infrastructure-as-code — Terraform modules and environments, GitHub Actions workflows — operating at the organization level. It provisions the accounts and the guardrails; it runs no cluster and no workload.

**Platform tier — `aegis-platform`.** The Kubernetes platform: the EKS cluster, the cluster add-ons, ArgoCD itself, and the GitOps deploy manifests that ArgoCD reconciles. It is the bridge between the account fabric below it and the application above it. It consumes the account fabric — it allocates VPC CIDRs from the landing zone's IPAM, assumes roles vended through the landing zone's OIDC provider — and it delivers the application by syncing its manifests into the cluster.

**App tier — `aegis-core`.** The application codebase (a C++ and Go Bazel monorepo) and its container build configuration via `rules_oci`, producing signed container images. Application engineers commit here using their normal PR review process. The App tier does not touch Kubernetes infrastructure; it produces images and the Platform tier deploys them.

The dependency direction is strictly one-way: App → Platform → Landing Zone. A higher tier consumes a lower tier's outputs; a lower tier never reaches up. The account fabric does not know the cluster exists; the cluster does not know which application image it is running until the App tier publishes one.

The contract between tiers is minimal and stable. The Landing Zone tier hands the Platform tier a set of accounts, a CIDR-allocation authority, and an OIDC trust surface — all of which change rarely. The Platform tier hands the cluster a set of GitOps manifests; ArgoCD reconciles them continuously. The App tier hands the Platform tier signed images by tag.

## Alternatives Considered

**Monorepo containing account fabric, platform, and application code.** Rejected. Account-fabric changes are high-blast-radius and infrequent — typically monthly. Application changes are low-blast-radius and frequent — several per day. A monorepo forces every application change through the same PR review and CI pipeline as organization-level changes, creating unnecessary friction for the high-frequency path and unnecessary visibility for the low-frequency path. Ownership boundaries become unclear: who reviews a change that touches both an SCP and a Kubernetes manifest? The monorepo pattern works at companies that have solved this with extensive internal tooling (Google, Meta) but is a trap for smaller projects without that tooling.

**Two repositories — infrastructure and application — with the cluster folded into the infrastructure repo.** Rejected. This is the obvious two-tier split, but it conflates two boundaries that have genuinely different cadences and reviewers. Organization-level guardrails change on a monthly cadence and are reviewed for compliance and blast radius; the cluster and its GitOps deploy manifests change far more often and are reviewed for platform behavior. Folding the cluster into the account fabric repo routes high-frequency platform changes through the same slow, high-scrutiny path as SCP changes. The three-tier split gives the Platform tier its own repository, its own CI cadence, and its own reviewers.

**Application Kubernetes manifests in the account-fabric repo, application code in a separate repo.** Rejected. This splits the application across two repos and forces account-fabric engineers to review every Kubernetes deployment change. The reviewers who should approve a replica count change are platform engineers, not the organization-fabric owner. It also makes the application's rollout cadence dependent on the account-fabric repo's PR queue, which is a throughput cliff.

**Push-based CD from a CI pipeline applying manifests directly.** Rejected. Push-based CD has no GitOps audit trail and makes drift detection harder. When the cluster diverges from the repository state — which always eventually happens, whether from an operator running `kubectl apply` or from a controller mutating a resource — there is no continuous reconciliation. ArgoCD's pull-based model is the opposite: it continuously reconciles cluster state against repository state, so drift is detected and corrected (or reported) without operator intervention.

**Single repo with a strict directory-level review assignment (CODEOWNERS).** Considered. CODEOWNERS can route review attention within a monorepo, which mitigates but does not eliminate the ownership confusion. The release cadence mismatch remains: a high-frequency app change still sits in the same queue as low-frequency fabric changes. This is a partial mitigation, not a solution.

## Consequences

Three repositories to maintain, each with its own CI, its own PR review process, and its own release cadence. The maintenance cost is real and is accepted as the price of clean ownership boundaries.

Cross-tier changes — a new service requiring an OIDC trust entry in the Landing Zone tier, a deploy manifest in the Platform tier, and a build target in the App tier — require coordinated commits in more than one repository. This is genuine friction. It is bounded: such cross-cutting changes are small relative to the total change volume, and the one-way dependency direction means each commit can land in tier order without circular waiting.

ArgoCD is the source of truth for application state in the cluster. If an operator directly modifies a Deployment via `kubectl apply`, ArgoCD detects the drift on its next reconciliation cycle and either reverts or reports it, depending on the sync policy configured per environment.

The tier model maps cleanly onto how real engineering organizations divide responsibilities — a cloud-foundations team, a platform team, and application teams. The commit history of each repo tells a coherent story scoped to its tier, which makes the boundary legible to any reviewer reading a single repository in isolation.
