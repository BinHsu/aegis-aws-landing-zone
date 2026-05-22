# 017. Platform Tier Extracted from the Landing Zone

## Status

Accepted (2026-05-22)

This ADR **retroactively documents an already-enacted split**. The platform
tier was extracted to a separate repository before this record was written:
`aegis-platform` is live and owns the EKS cluster, ArgoCD, Karpenter, the
observability stack, and the Qdrant attachment; this landing zone is fabric-only
today. The four-tier topology discussions repeatedly cited a descope ADR at a
number (in the 030s) that was never written — ldz ADRs only run to 016. This ADR
closes that phantom citation by recording the real decision at its correct
number, 017.

## Context

A landing zone can absorb platform-tier concerns by gravity. The repository that
already vends accounts, owns the OIDC trust surface, and runs the GitHub Actions
apply path is the path of least resistance for "just add the EKS cluster here
too." Early in the project the landing zone carried — or was on track to carry —
platform-tier responsibilities: the Kubernetes cluster, the GitOps control
plane, autoscaling, and observability.

Three forces motivated extracting them into a separate repository:

1. **Cost / lifecycle cadence.** The account fabric (Organizations, OUs, SCPs,
   IPAM, the OIDC provider) is created once and changes on a monthly cadence; it
   stays up. The platform tier (EKS, Karpenter, ArgoCD, observability) is
   destroyed and rebuilt in every DR drill and torn down for cost between drills.
   Coupling a once-created fabric to a routinely-destroyed cluster in one
   repository couples two wildly different lifecycles — exactly the coupling
   [ADR-001](001-landing-zone-scope-boundary.md)'s management-account boundary
   and [ADR-003](003-terraform-backend-bootstrap.md)'s per-layer state isolation
   exist to prevent, applied one tier outward.
2. **Blast radius.** Cluster churn — an EKS upgrade, a Karpenter NodePool
   rewrite, an ArgoCD reinstall — should never share a state file, an apply role,
   or a PR queue with org-level guardrails. Folding the platform into the fabric
   repo routes high-frequency, cluster-shaped change through the same
   high-scrutiny path as SCP changes.
3. **Conway's-law boundary.** The fabric is owned by a cloud-foundations
   posture; the platform is owned by a platform-engineering posture. Aligning the
   repository boundary with the ownership boundary is the same argument
   [ADR-007](007-infra-app-repository-split.md) already made — this ADR records
   that the split was actually enacted, not merely planned.

This ADR completes the lineage of [ADR-001](001-landing-zone-scope-boundary.md)
(scope boundary), [ADR-007](007-infra-app-repository-split.md) (infra / app
repository split and the tier model), and
[ADR-013](013-landing-zone-repo-topology.md) (the landing zone's *internal*
repo topology). ADR-007 named the Landing Zone / Platform / App tier model;
ADR-013 declined an internal split of the landing zone; this ADR records that
the Platform tier itself left the landing zone for `aegis-platform`.

## Decision

**The landing zone is scoped to the account fabric only. The platform tier lives
in `aegis-platform`. The workload tier lives in the deploy repos.**

**Landing-zone (this repository) scope — account fabric only:**

- AWS Organizations, OUs, and the OU taxonomy ([ADR-006](006-account-taxonomy-and-ou-structure.md)).
- Service Control Policies (region restriction, service guardrails, the IAM
  privilege-escalation deny — [ADR-015](015-permission-boundary-hardening.md)).
- Organization-wide IPAM as the single CIDR-allocation authority ([ADR-012](012-ipam-and-cidr-allocation.md)).
- AFT / account provisioning and bootstrap ([ADR-010](010-shared-account-bootstrap-sequence.md), [ADR-011](011-account-provisioning-two-path-strategy.md)).
- Control Tower + Terraform hybrid tooling ([ADR-008](008-landing-zone-tooling-control-tower-hybrid.md)).
- The GitHub OIDC identity provider — the **trust anchor** for every machine
  identity in the org.
- The org-level SCP `deny-iam-privilege-escalation` that caps IAM escalation
  org-wide — the wall lives above any single role's scope
  ([ADR-015](015-permission-boundary-hardening.md) §A2 chose the SCP over
  per-role permission boundaries; [ADR-014](014-iam-permission-scope-down.md)
  scoped the CI roles).

**Platform tier — `aegis-platform` (out of this repository):** the EKS cluster,
Karpenter, ArgoCD and its GitOps control plane, the observability stack, the
Qdrant attachment, and the per-region platform baseline (ALB controller,
external-dns, cert-manager, the ACK controllers, Kyverno). It consumes this
landing zone's outputs — it allocates CIDRs from IPAM and assumes roles vended
through the OIDC provider — and never reaches back up.

**Workload tier — the deploy repos** (`aegis-greeter-deploy`,
`aegis-core-deploy`): per-workload manifests, the workload `Application` CRs, and
the workload-scoped IAM the platform tier reconciles.

The dependency direction stays strictly one-way — Workload → Platform → Landing
Zone — exactly as [ADR-007](007-infra-app-repository-split.md) specified.

## Alternatives Considered

**Keep the platform tier in the landing zone (monorepo of fabric + platform).**
Rejected — and in practice already un-chosen. It couples a once-created fabric to
a routinely-destroyed cluster: one state file, one apply role, and one PR queue
spanning monthly org changes and per-drill cluster rebuilds. The blast radius of
a cluster mistake would reach org-level guardrails. This is the two-repo
"infrastructure + application with the cluster folded into infra" option ADR-007
already rejected, viewed from the fabric side.

**Extract the platform tier but keep workload IAM in the landing zone.**
Rejected as an incomplete split. The fabric should own the IAM *primitive* (the
OIDC trust anchor + the org-level SCP that caps escalation), not the
per-workload *role*. Keeping every workload's IRSA role in the fabric tier makes
each workload's identity scope a cross-repo change and re-introduces the upward
leak. The per-workload role belongs in the workload's deploy repo — see the
consequence below (and note no working per-workload role exists in the fabric
today regardless).

**A third "platform" repository owned by the landing zone but with a separate
state.** Rejected as the worst of both: it keeps the platform on the landing
zone's PR queue and CODEOWNERS surface while pretending at separation. If the
platform deserves its own lifecycle, it deserves its own repository — the
position [ADR-013](013-landing-zone-repo-topology.md) reached for *internal*
splits, applied to the tier boundary.

## Consequences

- The landing zone keeps only the **OIDC provider trust anchor** and the
  **org-level SCPs** (including `deny-iam-privilege-escalation`) as the ceiling
  on what any workload IAM can do. The per-workload *role* belongs in the
  workload's deploy repo (forward reference: **aegis-platform ADR-07**). Note the
  current state: no per-workload IRSA role is actually declared in this
  repository — `aegis-core-deploy`'s engine ServiceAccount carries a role-arn
  annotation pointing at `aegis-staging-aegis-engine`, but that role was never
  provisioned in this repo's Terraform (a dangling reference, not a working
  role). The roll-forward provisions it via ACK CRDs in the deploy repo and
  reconciles the dangling annotation; nothing is destroyed here. One real fabric
  change is required: the ACK controller role must be added to the
  `deny-iam-privilege-escalation` SCP allow-list (a scoped carve-out like the
  Karpenter entry) so ACK can create workload roles at all.
- The landing zone's `gh-tf-apply-baseline` IAM surface narrows over time as the
  per-workload IAM leaves: the apply tier still creates the OIDC provider and the
  fabric roles, but it stops creating per-workload IRSA roles. The
  `*-karpenter-controller` carve-out in
  [ADR-015](015-permission-boundary-hardening.md) is unaffected — it is a runtime
  controller in the *platform* tier's accounts, allow-listed at the org SCP.
- The four-tier-topology references to the phantom descope ADR are resolved. The
  descope they pointed at is this ADR. The stale phantom-number citations
  elsewhere in the repo
  (`config/schema.json`, `config/landing-zone.example.yaml`) are corrected to
  point here.
- The tier contract is unchanged from [ADR-007](007-infra-app-repository-split.md):
  the landing zone hands the platform tier a set of accounts, a CIDR-allocation
  authority, and an OIDC trust surface — all low-cadence — and never learns what
  runs on the cluster.

## Related

- [ADR-001](001-landing-zone-scope-boundary.md) — the scope boundary this ADR
  completes; the management-account / reproducibility principles it extends one
  tier outward.
- [ADR-007](007-infra-app-repository-split.md) — the Landing Zone / Platform /
  App tier model; this ADR records that the Platform tier was actually extracted.
- [ADR-013](013-landing-zone-repo-topology.md) — the landing zone's *internal*
  topology (declined a repo split); orthogonal to this ADR's *tier* extraction.
- [ADR-014](014-iam-permission-scope-down.md) / [ADR-015](015-permission-boundary-hardening.md)
  — the CI-role scope-down and the org-level `deny-iam-privilege-escalation` SCP
  the fabric retains as the escalation ceiling (ADR-015 §A2 chose the SCP over
  per-role permission boundaries).
- **aegis-platform ADR-07** — workload self-ownership; the consumer-side decision
  that pulls the per-workload IRSA role out of this landing zone.
- **aegis-platform ADR-08** — cluster multi-tenancy; the platform tier's own
  internal isolation model.
