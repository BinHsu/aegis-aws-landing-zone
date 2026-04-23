# 025. Qdrant backend — Cloud free tier

## Status

Accepted (2026-04-22).

## Context

aegis-core's Phase 4c demo needs a vector database behind its RAG retriever. The engine (`engine_cpp/src/vectordb/qdrant_client.cc`) already speaks the Qdrant gRPC API and reads `QDRANT_URL` + `QDRANT_API_KEY` via `ConfigFromEnv()`; a `engine seed --target=cloud` branch exists for ingesting the Taiwan corpus. What remained open was *where* the backend runs and *who* pays for it.

The question landed on landing-zone as cross-repo issue [#130](https://github.com/BinHsu/aegis-aws-landing-zone/issues/130), framed as a choice among three backends: in-cluster Qdrant StatefulSet (A), AWS OpenSearch Serverless (B), or Qdrant Cloud free tier (C). The decision affects this repo's platform surface — future SSM Parameter Store paths under `/aegis/<env>/qdrant-cloud/*` and an `ExternalSecret` wiring a Kubernetes Secret that the engine Deployment mounts — so it warrants an ADR rather than a comment-thread resolution.

The cost angle is not cosmetic. The lab's CLAUDE.md Cost Guardrail commits to **$5–10 per 4-hour session** for workload layers and **<$5 total for Phase 0–2**. A backend whose idle floor is higher than a single session budget is structurally incompatible with the lab's operating model. [ADR-022](022-observability-backend-grafana-cloud.md) established the pattern: when a managed free tier covers the portfolio scope, the cost-discipline argument dominates aesthetic preferences for self-hosting.

## Decision

Use **Qdrant Cloud free tier** (option C). Single cluster, hosted by Qdrant Labs, authenticated from the EKS cluster via API key delivered through the same SSM PS → External Secrets Operator → Kubernetes Secret chain established in [ADR-022](022-observability-backend-grafana-cloud.md).

Engine Deployments receive `QDRANT_URL` and `QDRANT_API_KEY` as env vars from a `qdrant-credentials` Secret reconciled by External Secrets Operator from SSM Parameter Store paths:

```
/aegis/<env>/qdrant-cloud/cluster-url
/aegis/<env>/qdrant-cloud/api-key
```

The `qdrant-cloud` prefix (rather than bare `qdrant`) mirrors the `grafana-cloud` convention from [ADR-022](022-observability-backend-grafana-cloud.md); the prefix names the *managed product*, not the open-source project, which keeps the SSM namespace stable if the lab ever runs a second Qdrant tier (e.g. a self-hosted Qdrant for an isolated experiment).

The free tier ceiling (1 GB storage, 1 M vectors) is sufficient for the portfolio's Taiwan corpus — a bounded-size document set whose embedding volume is well within one order of magnitude of the cap. Overage behavior is ingestion throttle, not auto-upgrade, because no payment method is attached to the account.

## Alternatives Considered

### A. In-cluster Qdrant StatefulSet

Run Qdrant as a StatefulSet on the EKS cluster, backed by EBS `gp3` PVCs, reconciled via ArgoCD.

Rejected on ops toil, not on cost (the cost is tolerable at ~$5–10/month idle for PVC + pod resources). What makes A unattractive is everything else the platform team then owns: PVC snapshot / restore lifecycle, Qdrant version upgrades (storage-format migrations are not always transparent), multi-region replication if [ADR-018](018-multi-region-eks-design.md)'s slave slot is ever called on to serve traffic, and the backup target (an S3 bucket with a retention policy, a test-restore job, and a runbook). All of this is production-quality database operation work that adds no new skill signal beyond the existing stateful stack (Karpenter + ArgoCD + cert-manager + External Secrets + grafana-operator) and competes for the same lab time as Phase 4c demo work.

A also does not benefit from the slot pattern the way compute does. A single-region in-cluster Qdrant is a single point of failure; making it HA on a single cluster requires Qdrant's distributed mode, which adds Raft operations to the ops surface. The lab does not carry that complexity budget.

### B. AWS OpenSearch Serverless (vector search collection)

Use OpenSearch Serverless with a vector search collection, replacing Qdrant client code in aegis-core with OpenSearch's k-NN API.

Rejected primarily on cost — and the cost failure is structural, not marginal. OpenSearch Serverless bills a **2-OCU minimum per collection** at **$0.24/OCU-hour**, i.e. ~**$346/month** idle floor for a single vector-search collection ($0.24 × 2 × 24 × 30). Even the smaller indexing/search OCU split at lower utilisation puts the monthly floor well above the Cost Guardrail's per-session ceiling. A backend whose idle cost exceeds a full session budget cannot coexist with a lab that teardowns between sessions.

A secondary rejection reason is the engine refactor cost. aegis-core's `qdrant_client.cc` maps gRPC calls to Qdrant's API shape; OpenSearch speaks REST + a different query DSL for k-NN. Switching backend at the engine layer is a week of aegis-core work for no portfolio gain, since the skill being demonstrated is "pick the right managed backend," not "port a vector-DB client."

### C. Qdrant Cloud free tier (chosen)

$0/month on the free tier at the portfolio's scale. Zero engine refactor — `QDRANT_URL` + `QDRANT_API_KEY` were already the engine's configuration contract. Ops surface collapses to credential rotation (same pattern as Grafana Cloud bootstrap tokens in [ADR-022](022-observability-backend-grafana-cloud.md)).

## Consequences

### Landing-zone implementation is deferred pending aegis-core Secret-contract issue

No Terraform or Helm change lands in landing-zone until aegis-core files a cross-repo issue specifying the Secret shape — key names, Deployment env-var mappings, and any additional config (collection name, embedding dimension, distance metric) the engine reads at startup. This mirrors the `team-webhooks` pattern from PR #128: platform provides the secret-delivery plumbing, the service team declares the contract it needs.

The aegis-core issue should arrive as `cross-repo` (non-blocking for now — the engine already works locally with a dev Qdrant). Platform work triggered on its arrival: (1) add `aws_ssm_parameter` SecureString resources under `/aegis/<env>/qdrant-cloud/*` in the layer owning the `aegis` namespace's secret delivery (likely `staging/observability/tokens.tf` extension or a new `staging/workloads/qdrant.tf`), matching the placeholder-value + `lifecycle.ignore_changes = [value]` pattern already used for `team-webhooks-slack-aegis`; (2) add an `ExternalSecret` manifest that reconciles `qdrant-credentials` into the `aegis` namespace; (3) document the bootstrap (one-time Qdrant Cloud console API key creation → `aws ssm put-parameter --overwrite`) in a new `docs/runbooks/007-qdrant-cloud-onboarding.md`.

Until the issue arrives, we do not speculate on the Secret shape; this repo has already paid the cost of guessing at cross-repo contracts (see CLAUDE.md "Wait for cross-repo issue before implementing").

### GDPR region posture

Qdrant Cloud free tier **offers AWS `eu-central-1` (Frankfurt)** — confirmed during first-time operator signup on 2026-04-23. This is strictly better than the earlier assumption (baked into the first drafts of this ADR and Runbook 007) that free tier was effectively US-only. Cluster placement in Frankfurt is compatible with GDPR obligations that apply broadly to Bin's professional context.

The lab's corpus remains **non-PII Taiwan documentation** by design, so Frankfurt placement is a better-than-required posture rather than a compliance requirement. The repo retains full flexibility to scale the corpus or re-frame the demo without triggering a region migration.

If scope ever expands beyond portfolio ceilings — real user queries, user-identifying metadata attached to vectors, or data volumes past the free tier's 1 GB / 1 M vector caps — the paid tier is a clean upgrade on the same `eu-central-1` region plus a DPA signature for real user data. It is a config change plus billing attachment, not a re-architecture.

### No engine refactor burden on aegis-core

The engine's `qdrant_client.cc` and `engine seed --target=cloud` branch are pre-existing. Option C changes two env vars' values; it changes zero lines of aegis-core code. This was the tipping-point argument in the [#130 decision comment](https://github.com/BinHsu/aegis-aws-landing-zone/issues/130#issuecomment-4294082568): both A and C reuse the existing client, but C additionally removes all ops toil; B demands a client rewrite at aegis-core's cost.

### Portfolio axis loss accepted

Choosing C forfeits the "operated a StatefulSet on EKS with PVC lifecycle management" interview talking point. This is a real loss against option A, but a bounded one: the existing stateful-component surface (EKS + Karpenter + ArgoCD + cert-manager + Kyverno + External Secrets + grafana-operator) already carries the platform-engineering signal this project aims to demonstrate. Adding a hand-operated vector DB would be a *repetition* of the stateful-workload skill in a context where the operational cost is highest (databases) rather than a new dimension.

The portfolio narrative instead carries "chose a managed backend on cost-discipline grounds, preserved a migration path via config-only swap" — which is the same class of argument ADR-022 records for observability, and which is the *actual* skill differentiator at staff / principal level.

### Future switch triggers

Revisit this ADR when any of the following fires:

- **Corpus scope changes**: crosses 1 M vectors or 1 GB stored embeddings → Qdrant Cloud paid tier (same client, same contract) or option A if ops budget has expanded.
- **GDPR scope changes**: real user data enters the vector store → paid tier upgrade on the same `eu-central-1` region + DPA signature.
- **Vendor risk materialises**: Qdrant Labs service deterioration, pricing model change, or acquisition affecting free-tier terms → option A becomes the escape hatch (same client code).
- **Multi-tenant or per-team vector isolation**: if future workloads need isolated vector namespaces with separate quotas → option A with per-namespace StatefulSets, or paid-tier multi-cluster Qdrant Cloud.

## Related

- [ADR-018](018-multi-region-eks-design.md) — slot pattern; Qdrant Cloud is single-endpoint so the slave slot accesses the same URL.
- [ADR-022](022-observability-backend-grafana-cloud.md) — the cost-discipline precedent for choosing managed free tiers over self-hosting when portfolio scope permits.
- [ADR-023](023-observability-responsibility-model.md) — External Secrets + SSM PS pattern reused here for the Qdrant credentials chain.
- landing-zone [#130](https://github.com/BinHsu/aegis-aws-landing-zone/issues/130) — decision record and cross-repo coordination thread.
