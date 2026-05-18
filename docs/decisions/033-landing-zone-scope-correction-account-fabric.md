# 033. Landing-zone scope correction — descope to account fabric, Platform tier extracted

## Status

Accepted (2026-05-17). **Physical extraction executed 2026-05-18** — see the update note below.

> **Update — 2026-05-18 (v2 descope executed).** Path A is complete. The
> physical extraction described below as "deferred to a dedicated future
> migration phase" has now been performed: the Platform-tier Terraform layers,
> their ADRs (013–023, 025–028, 032), and their runbooks (002–008) were
> removed from this repository, the CI workflows and config schema were
> trimmed, and `aegis-aws-landing-zone` now physically contains only the
> account fabric. **Open Question 1 is resolved** — the Platform-tier
> destination is a new repository, **`aegis-platform`** (cross-repo #214; that
> repo also becomes the no-review-gate GitOps Deploy source). Where the text
> below says the extraction is "deferred", "pending review", or that the
> destination is "not named", read it as done as of this date. The Platform
> layers themselves are recovered from the `v1.0.0` git tag by whoever stands
> up `aegis-platform` — this repository does not perform the move. The body
> below is otherwise preserved as written at decision time.

**Execution is phased (path A):** this ADR *records the boundary decision* now;
the *physical extraction* of the Platform-tier layers is deferred to a dedicated
future migration phase. Until that phase runs, the Platform-tier layers remain
physically in the landing-zone tree, flagged as tenants pending extraction.

Supersedes the in-scope list of [ADR-001](001-landing-zone-scope-boundary.md)
(the portion enumerating EKS / Karpenter / ArgoCD / Prometheus-Grafana as
landing-zone scope). Amends [ADR-007](007-infra-app-repository-split.md) (the
infra/app repo split widens from two repos to three-plus tiers). The inline
annotation of ADR-001 and ADR-007, and the runbook/ADR re-homing cascade, follow
once this ADR is reviewed and the Platform-tier destination is fixed.

## Context

[ADR-001](001-landing-zone-scope-boundary.md) drew this project's scope
boundary. Its in-scope list deliberately included the EKS cluster, Karpenter,
ArgoCD, and the Prometheus/Grafana observability stack. The recorded rationale
was a portfolio one: a repository that only stood up AWS Organizations, OUs,
SCPs, and Identity Center would not exercise — or display — the hands-on EKS,
GitOps, and autoscaling skills the project was built to demonstrate.

That rationale was **defensible under its original premise**: a single,
solo-operated repository, with no sibling repositories, where the only place to
show EKS work *was* this repository. It was a deliberate, documented trade-off,
not an oversight.

**The premise has since changed.** The surrounding ecosystem grew sibling
workload repositories — `aegis-core` (the application), and the
`aegis-stateless` / `aegis-greeter` and `aegis-statefulset` lines. A *Platform
tier* — the EKS cluster, ArgoCD, and the cluster add-ons that workloads run on —
now has, or could have, **more than one consumer**. [ADR-024](024-landing-zone-repo-topology.md)
already names exactly this class of signal ("team boundaries harden", sibling
ownership asserting itself) as a trigger to revisit repository structure.
Splitting, per ADR-024's own framing, "is a reaction to specific organizational
and operational constraints, not a milestone triggered by scale". That
constraint has now arrived.

There is also a **conceptual-correctness** dimension. In AWS practice a *landing
zone* is the multi-account governance fabric: AWS Organizations, the OU
structure, Service Control Policies, Identity Center, account vending, and the
centralized logging/audit baseline. It delivers *a governed, guard-railed
account an application team can land in*. The EKS cluster, ArgoCD, and cluster
add-ons are a *Platform tier* — conventionally owned by a separate platform
engineering function, in a separate repository. A repository named
`aegis-aws-landing-zone` that silently contains an entire EKS platform
misrepresents the term. For a portfolio artifact this is a *weaker* signal than
a correctly-scoped landing zone would be: knowing that a landing zone is not a
platform, and scoping accordingly, is itself the senior judgment worth showing.

This ADR corrects the scope. It is a **premise-change correction, not an
error correction** — ADR-001 was right for what it knew; this ADR is right for
what is now true.

## Decision

### The landing-zone repository's scope contracts to the *account fabric*

`aegis-aws-landing-zone` owns, and only owns, what governs AWS accounts and is
owned by no single workload:

1. **AWS Organizations and the OU structure** — `management/{bootstrap,scps}`,
   per [ADR-006](006-account-taxonomy-and-ou-structure.md).
2. **Service Control Policies** — the organizational guardrails.
3. **AWS Identity Center / SSO** — the sole human identity mechanism.
4. **Account bootstrap and vending** — the Control-Tower-plus-Terraform hybrid
   ([ADR-008](008-landing-zone-tooling-control-tower-hybrid.md)), Account Factory
   for Terraform, the Terraform state backend
   ([ADR-003](003-terraform-backend-bootstrap.md)), and the **account-singleton**
   GitHub OIDC identity provider.
5. **The centralized security and audit baseline** — the CloudTrail
   organization trail, AWS Config, and GuardDuty: organization-wide controls
   owned by no individual workload.

### Everything inside a workload account's *runtime* becomes the Platform tier

The VPC/network substrate, the EKS cluster, Karpenter, ArgoCD, the cluster
add-ons (Kyverno, cert-manager, External Secrets Operator), the observability
stack, the edge layer (CloudFront / ACM / Route53), Cognito auth, the FIS DR
drill, IRSA roles, workload namespaces/RBAC, and the root ArgoCD `Application`
custom resource are **no longer landing-zone scope**. They constitute a
*Platform tier* and will be extracted to a Platform-tier repository.

### The tier model

The two-repo split of ADR-007 widens to a tier model:

| Tier | Owns | Repository |
|---|---|---|
| **Landing Zone** | Account fabric (the five items above) | `aegis-aws-landing-zone` |
| **Platform** | VPC, EKS, ArgoCD, cluster add-ons, observability, edge, auth, FIS, IRSA, the root ArgoCD `Application` | *destination deferred — see Open Questions* |
| **App** | Application code, image build, signed/attested OCI artifacts | `aegis-core` |
| **Deploy** | GitOps K8s manifests, no review gate on the tag-bump path | *cross-repo #214 — `aegis-core-deploy` proposed* |

### Path A — record now, extract later

This ADR fixes the boundary and the reclassification. The **physical**
migration — moving the Platform-tier layers to their destination repository,
re-homing the affected ADRs and runbooks, splitting the CI workflows, re-wiring
backends and `terraform_remote_state` references — is deferred to a dedicated
future phase. The architectural value (the recorded reasoning and the corrected
boundary) is delivered by this ADR alone; the migration churn is not paid on a
torn-down lab until it is sequenced deliberately.

### First-cut layer classification

A starting classification for the eventual migration. Boundary-edge layers are
adjudicated per-layer at extraction time, not pre-decided here.

| Layer | Tier | Note |
|---|---|---|
| `management/{bootstrap,scps}` | Landing Zone | Organizations, OUs, SCPs |
| `shared/bootstrap` | Landing Zone | Shared-services account bootstrap |
| `prod/bootstrap`, `staging/bootstrap` | Landing Zone (mostly) | Account bootstrap; the GitHub OIDC *provider* is an account-singleton and stays — but the *workload* OIDC role is Platform-tier (boundary edge) |
| `staging/network` | Platform | VPC, subnets, NAT, endpoints |
| `staging/platform` | Platform | EKS, Karpenter, ArgoCD, Kyverno, cert-manager, ESO |
| `staging/workloads` | Platform | IRSA, namespace/RBAC |
| `staging/observability` | Platform | grafana-operator, GC tokens |
| `staging/edge` | Platform | CloudFront, ACM, Route53 |
| `staging/auth` | Platform | Cognito User Pool |
| `staging/fis` | Platform | DR drill |
| `staging/secrets-persistent` | Platform | SaaS-credential SSM shells; tied to workloads |
| `shared/ipam` | **Boundary edge** | IP address *governance* is arguably account-fabric; the VPCs that *consume* it are Platform — resolved at extraction time |

## Alternatives Considered

**A — Record the boundary now, extract physically later. (Chosen.)** The
architectural correction's value is the recorded reasoning. Path A delivers that
immediately, as a reviewable ADR, without paying a multi-session migration cost
on a lab that is currently torn down. The migration becomes its own deliberately
sequenced phase.

**B — Extract physically now.** Create the Platform-tier repository, move five-
to-seven layers, re-home roughly a dozen ADRs and six runbooks, split the CI
workflows. Rejected *for now*: it is a multi-session migration that would
disrupt the planned cold-apply re-validation and deliver no architectural
insight beyond what path A already records. B is not rejected forever — it is
the deferred execution phase.

**C — Keep ADR-001's scope unchanged.** Treat the broad scope as an accepted,
documented lab decision. Rejected: it leaves a repository named `landing-zone`
that materially misrepresents the term, which is a weaker portfolio signal than
a correctly-scoped one; and it ignores that ADR-024's documented split trigger
(sibling repositories / ownership boundaries) has genuinely fired.

**Was ADR-001's original scope an error?** No, and this ADR explicitly does not
frame it as one. ADR-001 was a defensible, documented trade-off under its
premise of a single solo repository. This ADR is a *premise-change* correction.
Recording it as such — rather than as a mistake — is itself the point: a
documented scope correction triggered by a changed constraint is a stronger
artifact than either an unchallenged broad scope or a self-flagellating retraction.

## Consequences

**Portfolio narrative strengthens.** A correctly-scoped landing zone, plus a
recorded ADR that says "the initial scope was deliberately broad for these
reasons; the ecosystem grew; here is the corrected tier model and why",
demonstrates the senior judgment of distinguishing a landing zone from a
platform — and of revisiting a decision on a *signal*, not a whim.

**ADR-024 remains valid, with a narrower domain.** ADR-024 governs the
*internal* topology of the landing-zone repository (single repo, logical
isolation via state/IAM/CI, declined per-account split). Its logic is unchanged;
it simply now applies to a smaller repository. ADR-024 is not superseded.

**A re-homing cascade is implied, not yet actioned.** When physical extraction
runs, the Platform-tier ADRs (`013`, `014`, `016`, `017`, `018`, `020`, `021`–`023`,
`025`, `026`, `027`, `032`) and the Platform-tier runbooks (`002`, `003`, `005`,
`006`, `007`, `008`) move with their layers. CLAUDE.md's directory structure and
layer descriptions are accurate *until* extraction and are updated at that time.
None of this is done in this ADR.

**The planned cold-apply re-validation is now in question.** A cold-apply of
layers that are about to be extracted to another repository may be wasted
effort. Whether to cold-apply before, after, or instead of the extraction is a
sequencing decision left open.

**Cross-repo coordination shifts counterparty.** Cross-repo issue #214 (move
aegis-core's deploy manifests to a no-review-gate GitOps repo) assigns its
contract's infrastructure column — EKS cluster, ArgoCD install, the ArgoCD
`Application` CR, ArgoCD repo credentials — to "landing-zone". Under this ADR
that column is owned by the **Platform-tier repository**, not the landing zone.
The #214 reply notes this; the deploy-repo decision should coordinate with the
Platform-tier destination.

**The IRSA rebind of cross-repo #213 still lands in landing-zone.** Per path A
the Platform-tier layers have not physically moved, so the engine IRSA
trust-policy subject fix (`staging/workloads`) is still applied in this
repository for now.

## Open Questions

These are deliberately left unresolved; resolving them is cross-repo work.

1. **Platform-tier destination repository.** Candidates: a new dedicated
   `aegis-core-platform` repository, or *folding the Platform tier into the
   existing `aegis-stateless` repository* — which already carries an ArgoCD
   install and is the precedent cited in cross-repo #214. This is an
   `aegis-core` / `aegis-stateless` topology decision, not one the landing zone
   can make unilaterally. Until it is fixed, this ADR does not name the
   Platform-tier repository.
2. **Boundary-edge layers.** `shared/ipam` (address governance vs. network),
   `staging/bootstrap` (account-singleton OIDC provider stays; workload OIDC
   role goes), `staging/edge`, `staging/auth`, `staging/secrets-persistent` —
   each adjudicated at extraction time.
3. **Network / VPC ownership.** If the Platform-tier repository is per-workload
   (`aegis-core-platform`), each workload repository brings its own VPC. If the
   Platform tier is shared across workloads, a distinct network sub-tier is
   implied. Tied to Open Question 1.
4. **Extraction sequencing vs. cold-apply.** See Consequences.

## Related

- [ADR-001](001-landing-zone-scope-boundary.md) — the scope boundary this ADR
  corrects (its in-scope list is superseded; inline annotation pending review).
- [ADR-007](007-infra-app-repository-split.md) — the infra/app split this ADR
  widens from two repos to a tier model (amendment pending review).
- [ADR-024](024-landing-zone-repo-topology.md) — landing-zone internal topology;
  remains valid, narrower domain. Its documented split triggers are what fired.
- ADR-013 (EKS architecture) — the canonical Platform-tier ADR; relocated to
  the `aegis-platform` repo, recoverable from the `v1.0.0` tag.
- Cross-repo `aegis-aws-landing-zone#214` — the GitOps deploy-repo RFC whose
  contract counterparty this ADR shifts.
