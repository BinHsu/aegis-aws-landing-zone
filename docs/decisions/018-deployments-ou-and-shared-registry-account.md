# 018. Deployments OU and `aegis-deployment` Account for the Shared Release-Artifact Registry

## Status

Proposed (2026-06-05)

Account creation is operator/Control-Tower-gated. This ADR records the fabric-side
decision; the account id stays a placeholder (empty string) in
`config/landing-zone.example.yaml` until the account is vended. The ECR registry
that justifies the account does **not** live here — it is the platform tier's job
([ADR-017](017-platform-tier-extraction.md)) and ships in the `aegis-platform-aws`
sibling PR.

## Context

The platform tier's release model (platform-aws **ADR-10**) is **build once, promote
by digest**: the workload image is built one time, and the immutable artifact is
promoted across environments by its content digest (`name@sha256:...`), never
rebuilt per environment. Environment differences — replica counts, resource limits,
ingress host, IAM trust — live in the deploy-repo overlays, not in the artifact.
The deploy repos pin images by `kustomize images[].digest`; the registry
(`newName`) is injected at ArgoCD sync time, so the deploy repos carry only
`name + digest`, not the registry URL.

That model needs **one** registry that **every** cluster account pulls from. The
cluster accounts that pull are `aegis-staging` and `aegis-prod` (both in the
Workloads OU). A single shared registry is what makes "promote the same digest"
true across environments — if staging and prod pulled from different registries,
the digest would no longer be the single source of identity for a release.

The open fabric-side question is **where that registry account sits**. The account
taxonomy ([ADR-006](006-account-taxonomy-and-ou-structure.md)) is a deliberate
subset of the AWS Security Reference Architecture (SRA) with the expansion path
called out as additive — and ADR-006 explicitly names a `Deployments` OU among the
full-SRA OUs it deferred:

> Full AWS SRA with `Sandbox`, `PolicyStaging`, `Suspended`, `Exceptions`, and
> `Deployments` OUs … When the project grows to warrant these OUs … the addition
> is additive, not a restructure.

The shared-registry requirement is exactly the trigger ADR-006 anticipated. AWS
SRA places shared deployment/CI artifacts (the central image registry, pipeline
artifacts) in a dedicated **Deployments** account under a **Deployments** OU,
separate from the shared-services / infrastructure account that holds the
control-plane state backend. This ADR takes that additive expansion path.

## Decision

**Add a `Deployments` OU and vend a dedicated `aegis-deployment` account under it.
The account hosts the single shared release-artifact registry (ECR) that the
build-once / promote-by-digest model pulls from. The fabric side — OU, account,
and bootstrap — lives here; the ECR resources live in `aegis-platform-aws`.**

Concretely, this repository:

- Adds the `Deployments` value to the OU enum in `config/schema.json` and an
  `accounts.deployment` block to `config/landing-zone.example.yaml`
  (`ou: Deployments`, placeholder id). `deployment` is **not** yet in the schema's
  `accounts.required` list — it graduates to required when the account is vended,
  mirroring the existing "empty id until provisioned" pattern (the account `id`
  pattern already permits the empty string).
- Adds `terraform/environments/deployment/bootstrap` — the same account-bootstrap
  shape as `staging/bootstrap`: account alias, the GitHub OIDC identity provider,
  the `gh-tf-plan` / `gh-tf-apply-baseline` CI roles, and the
  `aegis-emergency-break-glass` role. This is the landing zone's standard
  post-vend bootstrap, not new machinery.

What this repository does **not** do, by [ADR-017](017-platform-tier-extraction.md)'s
tier boundary:

- It does **not** create the ECR registry, its repositories, lifecycle policies,
  or cross-account pull policy — those are platform-tier resources in
  `aegis-platform-aws`.
- It does **not** create the platform-tier CI apply role that provisions ECR
  (`gh-tf-apply-deployment`) or the scoped workload OIDC push role
  (`ecr:PutImage`). Those mirror the org's `gh-tf-apply-*` OIDC pattern and ship in
  the platform-aws PR. The landing zone owns only the **OIDC provider trust
  anchor** in the deployment account (created by `deployment/bootstrap` above);
  the per-purpose roles federate against it downstream.

**No SCP change is required.** Both downstream roles are named `gh-tf-apply-deployment`
and a `gh-tf-*`-prefixed workload push role, and the org SCP
`deny-iam-privilege-escalation` already globs `arn:aws:iam::*:role/gh-tf-*` in its
allow-list (see `terraform/environments/management/scps/main.tf`). The new roles
fall inside the existing carve-out, exactly as
[ADR-014](014-iam-permission-scope-down.md)/[ADR-015](015-permission-boundary-hardening.md)
intended the `gh-tf-*` family to. The `Deployments` OU inherits the Root-attached
SCPs (region-deny, deny-root, deny-iam-user-creation, deny-iam-privilege-escalation)
the same way every other OU does.

## Alternatives Considered

**Co-locate the registry in `aegis-shared` (Infrastructure OU).** Rejected as a
category mismatch. `aegis-shared` holds the **control-plane** of the fabric: the
Terraform state backend, the org-wide IPAM authority, and the GitHub OIDC anchor —
low-cadence, fabric-lifecycle resources whose blast radius is the whole fabric. The
release registry is a **data-plane** artifact store on the workload-delivery
lifecycle: it churns on every release, it is pulled by workload clusters, and a
mistake there should not share an account boundary (or an apply role, or a PR
queue) with the Terraform state bucket. Folding the registry into `aegis-shared`
re-creates the exact lifecycle-coupling that [ADR-017](017-platform-tier-extraction.md)
extracted the platform tier to avoid, one tier down. AWS SRA separates the
Deployments account from the shared-services account for this reason; this ADR
follows that separation.

**A registry per cluster account (one in staging, one in prod).** Rejected — it
breaks the build-once / promote-by-digest invariant. If each environment pulled
from its own registry, promoting a release would mean copying the artifact between
registries, and the digest would no longer be a single, environment-independent
identity. The whole point of platform-aws ADR-10 is that the **same digest** moves
across environments; that requires **one** registry the cluster accounts share.
Per-account registries also multiply the cross-account trust surface and the
storage cost for no isolation benefit (the artifact is identical by construction).

**Keep the simplified 3-OU taxonomy and hang the account directly off Root.**
Rejected. ADR-006 attaches SCPs at the OU level precisely so account placement is
not ad-hoc; a Root-level account outside any OU is the management-account special
case ([ADR-001](001-landing-zone-scope-boundary.md)), not a pattern to copy for a
member account. Creating the `Deployments` OU is the additive, SRA-aligned move
ADR-006 already sanctioned, and it gives the registry account a named home for any
future Deployments-OU-scoped guardrail.

**Author a bespoke Deployments-OU hardening SCP now** (e.g. deny anything but ECR /
state / OIDC in the deployment account). Deferred, not rejected. The inherited
Root SCPs already cap the account (region-deny, no IAM users, no privilege
escalation), and the account is single-purpose by construction. A tailored
Deployments-OU SCP — for example constraining the account to ECR + the bootstrap
IAM surface, or denying image deletes outside a lifecycle policy — is a reasonable
hardening once the registry's real action surface is known. It is recorded here as
future work rather than guessed at before the platform-aws ECR PR lands.

## Consequences

- The fabric grows from six accounts / three OUs to **seven accounts / four OUs**.
  The addition is additive per ADR-006 — no existing account moves OU, no Root SCP
  changes, the region/IPAM/identity layers are untouched.
- `config/landing-zone.example.yaml` and `config/schema.json` gain the
  `deployment` account and the `Deployments` OU value. A forker's live
  `config/landing-zone.yaml` keeps validating unchanged because `deployment` is not
  yet `required`; it becomes required when the account is vended (the same
  graduation the empty-id pattern already encodes).
- A new Terraform layer `deployment/bootstrap` exists with state key
  `deployment/bootstrap/terraform.tfstate`. It cannot apply until the account id is
  filled in — the `check "config_account_id_not_empty"` block fails fast with the
  Runbook 001 Part 9 pointer, exactly like `staging/bootstrap` and `prod/bootstrap`.
- The `gh-tf-apply-deployment` and workload push roles land in `aegis-platform-aws`
  with **zero** SCP change here — the `gh-tf-*` carve-out already covers them. This
  is the superseding mechanism working as designed: the landing zone reserved the
  `gh-tf-*` namespace at the SCP, and a new consumer joins it without a fabric
  amendment.
- The dependency direction stays one-way (Workload → Platform → Landing Zone): the
  landing zone hands the platform tier an account + an OIDC trust anchor; the
  platform tier builds the registry inside it and never reaches back up.
- Deferred: a bespoke Deployments-OU hardening SCP, sized to the registry's real
  action surface once the platform-aws ECR PR defines it.

## Related

- [ADR-006](006-account-taxonomy-and-ou-structure.md) — the account/OU taxonomy
  this ADR extends; ADR-006 explicitly named the `Deployments` OU as a deferred,
  additive SRA expansion, and this ADR takes that path.
- [ADR-017](017-platform-tier-extraction.md) — the tier boundary that puts the ECR
  registry (a platform-tier resource) in `aegis-platform-aws` while the account
  fabric (OU + account + bootstrap + OIDC anchor) stays here.
- [ADR-014](014-iam-permission-scope-down.md) / [ADR-015](015-permission-boundary-hardening.md)
  — the `gh-tf-*` CI-role family and the org SCP `deny-iam-privilege-escalation`
  whose `gh-tf-*` allow-list glob covers `gh-tf-apply-deployment` with no SCP change.
- [ADR-001](001-landing-zone-scope-boundary.md) — the scope/blast-radius principles
  the "don't co-locate in aegis-shared" rejection extends one account outward.
- **aegis-platform-aws ADR-10** — build once, promote by digest, single shared
  registry in a dedicated Deployment account; the consumer-side decision this
  fabric-side ADR fulfils.
