# 028. Persistent SaaS-credential isolation

## Status

Accepted (2026-04-25).

## Context

[Incident 33](../incidents.md#incident-33--lbc-webhook-race-recurrence-across-helm_releases-2026-04-25) ended in a 3-retry teardown sequence. As part of the recovery the `terraform-teardown-workload.yml` workflow destroyed `staging/observability/`, which is the **first** layer the matrix tears down. Among the resources destroyed were:

| SSM PS path | TF resource | What was lost |
|---|---|---|
| `/aegis/staging/qdrant-cloud/cluster-url` | `aws_ssm_parameter.qdrant_cluster_url` | Cluster URL (recoverable from Qdrant Portal) |
| `/aegis/staging/qdrant-cloud/api-key` | `aws_ssm_parameter.qdrant_api_key` | **API key — Qdrant Portal shows it once at creation** |

Both resources had `lifecycle.ignore_changes = [value]` set. The block's contract is *"Terraform will not detect or attempt to fix drift on the listed attributes,"* which guards against `apply`-time clobbering by the placeholder value. **It does not guard against `destroy`.** A `terraform destroy` removes the resource regardless of `ignore_changes`.

Result: the operator had to revisit Qdrant Cloud Portal, generate a new 90-day API key, and run two `aws ssm put-parameter` calls before the next cold-apply could run. Net cost: ~15 minutes plus the cognitive tax of remembering this is now a manual prereq for every cold-apply.

The same failure mode applies to **any SSM PS whose source of truth is a SaaS portal that does not retain the value after first display**:

- Qdrant Cloud API key (90-day, one-time-display)
- Grafana Cloud bootstrap-token (30-day, one-time-display, requires Runbook 006 §Part 2 to re-issue)
- Future: any third-party API key onboarded under the Path B pattern (operator `put-parameter` + `lifecycle.ignore_changes`)

These credentials share three properties:

1. **TF cannot regenerate them** — the value is minted by an external SaaS and not stored anywhere TF can read.
2. **Loss has a real recovery cost** — operator portal visit, manual key issuance, sometimes a runbook re-execution.
3. **The TF resource shell is still useful** — for path canonicalization, KMS encryption, IAM scoping, and audit visibility. Removing TF ownership entirely (Option D below) is overkill.

The existing `staging/observability/` layer mixes these credentials with TF-generated tokens (e.g. `alloy_token`, `grafana_operator_token` produced by the `grafana` provider) and with K8s `ExternalSecret` CRDs. It is a workload-tier layer, in the teardown matrix by design.

The question this ADR answers: *where should persistent SaaS credentials live so that routine `terraform-teardown-workload.yml` runs cannot destroy them?*

[ADR-027](027-intra-environment-layer-sharding.md) gave us a framework for *when* a layer should shard. Two of its four triggers fire here:

- **Apply cadence divergence**: SaaS-credential SSM PS shells should never apply or destroy on workload cycles. They are baseline-tier in spirit. Their cadence is decoupled from the rest of `observability/`.
- **Permission boundary change**: arguably the persistent-credential layer is a stricter permission boundary — operators authorized to teardown workloads should not be authorized to teardown persistent credentials.

That makes a shard the right move now, not after the next incident.

## Decision

**Create `staging/secrets-persistent/` as a baseline-tier Terraservice layer that owns Path-B SSM PS shells for SaaS credentials. Exclude it from `terraform-apply-workload.yml` and `terraform-teardown-workload.yml` matrices.**

### Scope: 4 SSM PS resources

| SSM PS path | Origin | Lifecycle |
|---|---|---|
| `/aegis/staging/qdrant-cloud/cluster-url` | Operator copies from Qdrant Portal once at onboarding | `ignore_changes = [value]` |
| `/aegis/staging/qdrant-cloud/api-key` | Qdrant Portal one-time display, 90-day rotation per Runbook 007 | `ignore_changes = [value]` |
| `/aegis/staging/grafana-cloud/bootstrap-token` | Grafana Cloud one-time display, 30-day rotation per Runbook 006 §Part 2 | `ignore_changes = [value]` |
| `/aegis/staging/grafana-cloud/team-webhooks-slack-aegis` | Slack workspace Incoming Webhook URL (Runbook 006 §Part 4 — added by this PR) | `ignore_changes = [value]` |

`bootstrap-token` is brought **under Terraform management for the first time** via Terraform 1.5+ `import { }` block. Today it lives only as a `data "aws_ssm_parameter"` lookup in `staging/observability/config.tf`; the manual `put-parameter` from Runbook 006 has no TF resource shell. The new layer adopts the existing AWS-side parameter on first apply.

`team-webhooks-slack-aegis` is currently a placeholder resource in `staging/observability/tokens.tf` with `value = "placeholder-operator-must-overwrite"`. The actual Slack webhook URL has never been put. Migrating it to `secrets-persistent/` is forward-looking: when the operator eventually creates a Slack Incoming Webhook (Runbook 006 §Part 4), the value lands in a layer that survives teardown.

### Out of scope: TF-generated tokens stay in observability

`alloy_token`, `grafana_operator_token`, and the Cognito SSM parameters (`/aegis/staging/cognito/*`) **stay where they are**:

- `alloy_token` + `grafana_operator_token` are produced by the `grafana` provider during `staging/observability/` apply. The SSM PS resource and its source resource are the same lifecycle owner. Splitting them across layers introduces a cross-layer producer-consumer with no real benefit (TF can regenerate both on next apply via the bootstrap-token lookup).
- Cognito SSM parameters mirror `aws_cognito_user_pool` attributes. The pool itself has `lifecycle.prevent_destroy = true` and lives in `staging/auth/`, also baseline-tier and outside the workload teardown matrix. Already protected.

### SSM path prefix unchanged

The new layer **does not** rename SSM paths. `/aegis/staging/grafana-cloud/*` and `/aegis/staging/qdrant-cloud/*` remain the canonical paths. This preserves the IRSA policy in `staging/platform/modules/eks-cluster/external-secrets-iam.tf` (wildcard scoped to the path, not to TF state ownership) and the `data "aws_ssm_parameter"` lookups elsewhere (which read from AWS, not from TF state).

### ExternalSecret CRDs stay in observability

The `kubectl_manifest` ExternalSecret resources (`external_secret_qdrant_credentials`, `external_secret_team_webhooks`, etc.) **remain in `staging/observability/`**. They are K8s resources that target K8s namespaces (`monitoring`, `observability`, `aegis`), which require the workloads layer to have applied. The observability layer already wires the kubectl provider against the cluster; secrets-persistent has no such wiring and shouldn't.

The `depends_on = [aws_ssm_parameter.qdrant_cluster_url, …]` lines in `external-secrets.tf` and `qdrant-scaffold.tf` are removed. Apply-time ordering is now enforced by the workflow split (baseline → workload). Out-of-order operator local applies (e.g. running `staging/observability/` before `staging/secrets-persistent/`) result in ESO logging "Secret not found" and retrying — eventual consistency holds, no apply-time error.

### Workflow placement

| Workflow | Includes `staging/secrets-persistent/`? | Reason |
|---|---|---|
| `terraform-plan.yml` | ✅ | Drift detection on every PR |
| `terraform-apply-baseline.yml` | ✅ — ordered after `staging/bootstrap` (KMS alias dependency) and before `staging/auth` | Auto-apply on merge, $0 idle |
| `terraform-apply-workload.yml` | ❌ | Workload-tier layers only |
| `terraform-teardown-workload.yml` | ❌ | This is the entire point of the layer |

## Alternatives Considered

### A. Keep in `staging/observability/` + `lifecycle.prevent_destroy = true`

Rejected. `prevent_destroy` makes `terraform-teardown-workload.yml` hard-fail. Operator workaround would be `terraform destroy -target=...` to skip the protected resources, which is exactly the kind of imperative override that erodes the discipline of "the workflow is the source of truth for teardown order." The protection becomes adversarial to the very workflow it is supposed to coexist with.

### B. Move only Qdrant credentials, leave others

Rejected. The `bootstrap-token` is also Path-B (Runbook 006 §Part 2 manual put), 30-day expiry, one-time-display from Grafana Cloud. The same failure mode applies. Treating Qdrant as special would leave a known regression for the next teardown to discover. ADR-022 §Token rotation didn't surface this because at the time the only path-B credential was the bootstrap-token, observability had not yet been added to the teardown matrix in the way that destroyed it (PR-4 of ADR-022 added `observability` to the teardown order on 2026-04-22).

### C. Move to `shared/secrets/` (cross-environment)

Rejected. The `shared/` namespace in this repo is for cross-account / cross-environment infrastructure — `shared/bootstrap`, `shared/ipam`, `shared/aft`. SaaS credentials are environment-scoped: the staging Qdrant cluster URL is not the same as the future prod Qdrant cluster URL, the staging Grafana stack is not the same as a future prod stack. Putting staging credentials in `shared/` invites a future contributor to accidentally collide with prod paths. `staging/secrets-persistent/` (and a future `prod/secrets-persistent/`) is the correct boundary.

### D. Remove from Terraform entirely — pure manual + AWS CLI

Rejected. Loses the audit trail, the KMS encryption guarantee in the resource shell (TF enforces `key_id = data.aws_kms_alias.secrets[...].target_key_arn`), and the tagging discipline that makes `aws ssm describe-parameters --filters Key=tag:ManagedBy,Values=terraform` a useful diagnostic. The "shell in TF, value out-of-band" pattern is an explicit project convention — see Runbook 007 §Part 3 Path B. ADR-028 reinforces it, doesn't replace it.

### E. Add a per-resource pre-destroy hook to back up values

Rejected as over-engineering. There is no general "pre-destroy backup" mechanism in Terraform; we would have to build one (CloudWatch event → Lambda → KMS-encrypted S3 backup). The complexity-to-benefit ratio is much worse than just moving the resources to a layer that doesn't get destroyed.

## Consequences

### Makes easier

- The `terraform-teardown-workload.yml` matrix becomes physically incapable of destroying SaaS credentials. Future cold-apply prereqs do not include "remember to regenerate these values."
- Layer name `secrets-persistent` self-documents that the layer is teardown-immune. Any future PR proposing to add it to the workload teardown matrix is obviously wrong on the file path alone.
- Onboarding a new SaaS credential (say, GitHub App private key for an integration) follows a clear template: add resource to `staging/secrets-persistent/`, document the runbook step for value provisioning, done. No per-credential lifecycle gymnastics.
- Recovery from a missed `aws ssm put-parameter` is bounded — only the 4 enumerated paths can be at risk, all are listed in this ADR.

### Makes harder

- One additional layer in plan + baseline-apply matrices. Plan time grows by ~10-20s. Trivial.
- ExternalSecret CRDs in `observability/` lose explicit `depends_on` to the SSM PS resources (now in another state). Apply-time ordering shifts to workflow-level (baseline before workload). A solo operator running `terraform apply` locally out of order will see ESO retry loops, not a TF error. Acceptable — out-of-order local apply was never a supported operator path.
- The Category A / Category B distinction (manual-put-from-SaaS vs TF-generated) becomes a per-credential judgment when a new credential is onboarded. The decision lives in the runbook for that credential, not automated. The 4-row table above is the canonical scope; expanding it requires an ADR amendment.
- `bootstrap-token` adoption via `import { }` block is a one-time complexity. After first apply, the `import` block is no-op (Terraform 1.5+ idempotent) but the .tf file carries it indefinitely. A follow-up cleanup PR can remove it once a forker's first apply has landed.

## Related

- [ADR-022](022-observability-stack-grafana-cloud-only.md) — introduced the bootstrap-token + downstream-token model. ADR-028 fixes a gap that ADR-022 §Token rotation did not foresee: the persistence story across teardown cycles.
- [ADR-025](025-qdrant-backend-cloud-free-tier.md) — introduced Qdrant Cloud as a SaaS dependency and the `qdrant-cloud/` SSM PS path. ADR-028 protects those values.
- [ADR-027](027-intra-environment-layer-sharding.md) — sibling framework. ADR-027 was about *when not to shard*; ADR-028 documents an instance where two of its four triggers (apply cadence, permission boundary) fired and a shard was warranted.
- [Incident 33](../incidents.md#incident-33--lbc-webhook-race-recurrence-across-helm_releases-2026-04-25) — the postmortem that surfaced this gap.
- [Incident 34](../incidents.md#incident-34--lifecycleignore_changes-does-not-protect-against-destroy-2026-04-25) — narrower postmortem on the `lifecycle.ignore_changes` semantics misunderstanding.
- [Runbook 006](../runbooks/006-grafana-cloud-onboarding.md) — bootstrap-token onboarding + new §Slack webhook section that pre-dates the operator filling team-webhooks-slack-aegis.
- [Runbook 007](../runbooks/007-qdrant-cloud-onboarding.md) — Qdrant Cloud onboarding + Path B retrofit, now retargeted at `staging/secrets-persistent/`.
