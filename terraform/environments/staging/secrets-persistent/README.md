<!-- session-close-review: scope changes (4-row table in ADR-028 §Decision §Scope) — keep this README's resource inventory in sync if the scope grows or shrinks; reference ADR-028 in the same edit -->

# staging/secrets-persistent

Baseline-tier Terraservice layer that owns Path-B SSM PS shells for SaaS credentials whose source-of-truth is an external SaaS portal. Implements [ADR-028](../../../../docs/decisions/028-persistent-saas-credential-isolation.md).

## What this layer owns

Four SSM PS SecureString resources, all encrypted with the shared `alias/aegis-staging-secrets` KMS key:

| SSM path | Source of truth | Rotation | Consumer |
|---|---|---|---|
| `/aegis/staging/grafana-cloud/bootstrap-token` | Grafana Cloud portal (one-time display, 30-day) | Runbook 006 §Token rotation | `staging/observability` `data` source → `grafana.cloud` provider |
| `/aegis/staging/grafana-cloud/team-webhooks-slack-aegis` | Slack workspace Incoming Webhook | Runbook 006 §Part 4 | ExternalSecret `team-webhooks` → aegis-core GrafanaContactPoint |
| `/aegis/staging/qdrant-cloud/cluster-url` | Qdrant Cloud portal | Stable across api-key rotation | ExternalSecret `qdrant-credentials` (key `QDRANT_URL`) |
| `/aegis/staging/qdrant-cloud/api-key` | Qdrant Cloud portal (one-time display, 90-day) | Runbook 007 §API key rotation | ExternalSecret `qdrant-credentials` (key `QDRANT_API_KEY`) |

All four resources use `lifecycle.ignore_changes = [value]`. Terraform creates the SecureString shell with a placeholder value; the operator `put-parameter`s the real value out-of-band per the relevant runbook. Subsequent applies do not clobber the operator-supplied value.

## What this layer does NOT own

- **ExternalSecret CRDs** (`team-webhooks`, `qdrant-credentials`, `cognito-config`) — owned by `staging/observability/` and `staging/auth/` respectively. They live with the K8s providers and namespace dependencies in those layers (ADR-028 §ExternalSecret CRDs stay in observability).
- **TF-generated tokens** (`alloy-token`, `grafana-operator-token`) — owned by `staging/observability/tokens.tf`. The `grafana` provider mints these from the bootstrap-token; their TF resource and source-of-truth share a lifecycle owner. Splitting them across layers introduces a cross-layer producer-consumer with no benefit (ADR-028 §Out of scope).
- **Cognito SSM parameters** (`/aegis/staging/cognito/*`) — owned by `staging/auth/`. Already protected by the User Pool's `lifecycle.prevent_destroy = true` and by `staging/auth/`'s exclusion from the workload teardown matrix.

## Apply order

This is a **baseline-tier peer layer** with auto-apply on merge to `main`. Long-lived: never torn down by `terraform-teardown-workload.yml`. That immunity is the entire point of the layer (ADR-028 §Decision).

```
baseline tier (auto-apply on merge, never torn down):
  management/bootstrap → management/scps → shared/bootstrap → shared/ipam
  staging/bootstrap → staging/secrets-persistent → staging/auth → staging/edge

workload tier (manual dispatch, torn down at session end):
  staging/network → staging/platform → staging/workloads → staging/observability
```

Ordered after `staging/bootstrap` (KMS alias dependency) and before `staging/auth` so secret-related layers cluster together in the matrix.

## First-apply prerequisites

The `bootstrap-token` import block in `imports.tf` adopts a pre-existing AWS-side SSM PS into Terraform state. **First apply requires Runbook 006 §Part 2 to have executed** (operator manually `put-parameter`s the bootstrap-token from Grafana Cloud portal). Without the pre-existing parameter, the import block fails with "no SSM parameter found".

Forkers: this is not a new constraint. Runbook 006 §Part 2 has always been a pre-apply prerequisite for any layer that authenticates against Grafana Cloud — ADR-028 just brings the resource shell under TF management.

The other three SSM parameters do **not** require pre-apply provisioning. Terraform creates them with placeholder values; operator `put-parameter --overwrite`s the real value any time after first apply, per the relevant runbook. The `lifecycle.ignore_changes = [value]` block ensures the real value is preserved across subsequent applies.

## Cold-cycle interaction with `staging/observability/`

`staging/observability/` reads `bootstrap-token` via `data "aws_ssm_parameter"` and reads the other three via runtime ESO ClusterSecretStore. None of those reads chain TF state — they read AWS directly. So `secrets-persistent/` and `observability/` have **no Terraform-state-level dependency**. Apply-time correctness depends on workflow ordering (baseline runs before workload), enforced by the workflow split.

If the operator runs `terraform apply` locally out of order — say, applying `staging/observability/` before `staging/secrets-persistent/` — `staging/observability/`'s `data.aws_ssm_parameter.bootstrap_token` will fail with `NoSuchKey`. Recovery: apply `staging/secrets-persistent/` first. ESO-managed credentials (qdrant + slack) are eventually-consistent: ESO retries on missing-key and reconciles whenever the SSM PS appears.

## Terraform file inventory

| File | Purpose |
|---|---|
| `backend.tf` | S3 native-locking backend. Generated by `scripts/configure-backends.sh` from `config/landing-zone.yaml`. |
| `versions.tf` | Provider versions — `aws ~> 6.40` only. No K8s providers. |
| `providers.tf` | AWS provider for the primary region with `default_tags` and `allowed_account_ids` guard. |
| `config.tf` | `yamldecode` of `config/landing-zone.yaml`; per-credential gates (`grafana_cloud_enabled`, `qdrant_enabled`); KMS alias lookup; account + region invariant checks. |
| `grafana-cloud.tf` | Two SSM PS resources for `bootstrap-token` and `team-webhooks-slack-aegis`. |
| `qdrant.tf` | Two SSM PS resources for `cluster-url` and `api-key`. |
| `imports.tf` | Single `import { }` block that adopts the pre-existing `bootstrap-token` AWS resource on first apply. |
| `outputs.tf` | Three operator-inspection outputs: gate values + canonical SSM path map. |

## Resource inventory (full plan when both gates enabled)

| Resource | Path | Notes |
|---|---|---|
| `aws_ssm_parameter.bootstrap_token[0]` | `/aegis/staging/grafana-cloud/bootstrap-token` | Adopted via import block on first apply |
| `aws_ssm_parameter.team_webhooks_slack_aegis[0]` | `/aegis/staging/grafana-cloud/team-webhooks-slack-aegis` | Created with placeholder; real value per Runbook 006 §Part 4 |
| `aws_ssm_parameter.qdrant_cluster_url[0]` | `/aegis/staging/qdrant-cloud/cluster-url` | Created with placeholder; real value per Runbook 007 §Part 2 |
| `aws_ssm_parameter.qdrant_api_key[0]` | `/aegis/staging/qdrant-cloud/api-key` | Created with placeholder; real value per Runbook 007 §Part 2 (90-day rotation) |

## Why this layer exists

[Incident 33](../../../../docs/incidents.md#incident-33--lbc-webhook-race-recurrence-across-helm_releases-2026-04-25) ended with a 3-retry teardown sequence that destroyed `staging/observability/`. Among the resources destroyed: `aws_ssm_parameter.qdrant_cluster_url` and `aws_ssm_parameter.qdrant_api_key`. Both had `lifecycle.ignore_changes = [value]`, but [Incident 34](../../../../docs/incidents.md#incident-34--lifecycleignore_changes-does-not-protect-against-destroy-2026-04-25) documents that this block only guards against `apply`-time clobbering, not against `destroy`. The api-key is one-time-display from the Qdrant portal — operator had to revisit the portal, generate a new 90-day key, and `put-parameter` it before the next cold-apply could run.

The same failure mode applies to any SSM PS sourced from a SaaS portal that does not retain values after first display. ADR-028 enumerates the 4-resource scope.
