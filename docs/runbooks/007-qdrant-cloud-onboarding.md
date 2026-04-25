<!-- session-close-review: when lab operator needs a fresh Qdrant Cloud cluster, rotates the API key, migrates to a different Qdrant Cloud cluster (region or account change), or when the ldz ↔ aegis-core Qdrant contract shape changes (env var names, Secret keys, additional fields, or Terraform scaffolding shape in staging/secrets-persistent/qdrant.tf or staging/observability/qdrant-external-secret.tf) -->
# 007. Qdrant Cloud free tier — onboarding and credential rotation

> **When to read this**: you are doing a first-time Qdrant Cloud signup for this lab, rotating the cluster's API key, or migrating to a new Qdrant Cloud cluster. This is NOT a per-session runbook — the Qdrant Cloud cluster is a persistent SaaS resource, not a per-session workload. Reading in full takes <5 minutes.

## When to use

- First-time signup for this lab (Bin or any forker)
- API key rotation (every 90 days, mirroring Grafana Cloud downstream token cadence)
- Migrating to a new Qdrant Cloud cluster (region change, account change, corpus re-ingest)

Related: [ADR-025](../decisions/025-qdrant-backend-cloud-free-tier.md) (backend decision), [ADR-023](../decisions/023-observability-responsibility-model.md) (External Secrets + SSM PS pattern reused here), [Runbook 006](006-grafana-cloud-onboarding.md) (sibling SaaS onboarding — Grafana Cloud uses the same credential-plumbing shape).

---

## Pre-flight

- AWS CLI + AWS SSO login to `aegis-staging` active (`aws sso login --sso-session aegis`; `export AWS_PROFILE=aegis-staging-admin`)
- Browser with Gmail / GitHub available (account root will be bound to one of these)
- 20–30 minutes for first-time setup; 10 minutes for rotation
- No payment method required for free tier
- Do NOT attach a credit card — keeps overage behavior on ingest-throttle, not auto-upgrade. Same free-tier discipline as Runbook 006.
- GDPR posture: Qdrant Cloud free tier **offers AWS `eu-central-1` (Frankfurt)** — confirmed 2026-04-23. Pick Frankfurt unless operating from a non-EU locale. See [ADR-025](../decisions/025-qdrant-backend-cloud-free-tier.md) §GDPR region posture for the full rationale and upgrade path.

---

## Part 1 — Sign up and create cluster

1. Navigate to `https://cloud.qdrant.io/signup`
2. Sign up with Gmail or GitHub OAuth. Note: this account is the org root and is difficult to change later. Lab uses `pcpunkhades@gmail.com`.
3. Accept any Terms / DPA prompts — free tier runs on Qdrant Labs' managed infrastructure; no additional contract is required.
4. Navigate to the Cloud Dashboard → **Clusters** → click **+ Create**
5. Create cluster:
   - Tier: **Free**
   - Cloud provider: **AWS** (Qdrant Cloud also offers GCP and Azure; AWS aligns with the lab's existing posture)
   - Region: **`eu-central-1` (Frankfurt)** — available on free tier as confirmed 2026-04-23. Pick Frankfurt if deploying from Germany / EU; other EU regions may also be available. If Qdrant Cloud ever narrows free-tier region selection in future, re-consult [ADR-025](../decisions/025-qdrant-backend-cloud-free-tier.md) §GDPR region posture.
   - Cluster name: `aegis-staging-vectors` (or your preferred name — this is not load-bearing; the engine reads the URL from SSM PS, not the cluster name)
6. Click **Create**. Cluster provisioning takes ~1–2 minutes.
7. Once the cluster shows as `Healthy` in the Clusters menu, click into it to see the **Cluster Detail** page.

**Free tier resource envelope** (confirm on the Qdrant Cloud pricing page at onboarding time — terms are subject to change): 0.5 vCPU, 1 GB RAM, 4 GB disk, single-node cluster. Sufficient for the lab's bounded Taiwan corpus per ADR-025.

---

## Part 2 — Capture credentials

From the **Cluster Detail** page, record two pieces of information:

1. **Cluster endpoint URL** — shown as a hostname like `<cluster-id>.<region>.<provider>.cloud.qdrant.io`. The cluster speaks REST on port **6333** and gRPC on port **6334** (both reachable on the same hostname). The engine (`engine_cpp/src/vectordb/qdrant_client.cc`) uses **gRPC on 6334** — confirm this in the engine's `ConfigFromEnv()` path before committing the URL to SSM PS.

2. **API key** — Qdrant Cloud does not auto-generate a key on cluster creation; you must create one explicitly.

   Navigation: **Cluster Detail page → API Keys tab → + Create** (exact path confirmed against the current Qdrant Cloud docs; UI may minor-version drift).

   Settings:
   - Name: `engine-<YYYYMMDD>`
   - Expiration: **90 days** (mirrors the Grafana Cloud downstream token rotation cadence in Runbook 006)
   - Permission level: **manage/write** (default). The engine needs write permission to ingest via `engine seed --target=cloud`; read-only would block ingestion.
   - Collections scope: leave unrestricted for now (single-workload cluster). If multi-collection isolation becomes a requirement, scope per-collection later.

3. Click **Create**. **COPY THE API KEY** — shown only once. Qdrant Cloud does not let you retrieve it later; a lost key means creating a new one and re-puttting to SSM PS.

Auth header for later verification: Qdrant Cloud accepts **both** `api-key: <key>` header and `Authorization: Bearer <key>` header. The engine uses whichever its client library defaults to; for the curl test in Part 4, either format works.

---

## Part 3 — Stash credentials in SSM Parameter Store

> ⚠️ **Credentials go in SSM Parameter Store — never in `config/landing-zone.yaml`.** The `config.yaml` file holds deployment-shape metadata (account IDs, emails, CIDRs) per CLAUDE.md §Security; API keys and session tokens are categorically distinct and must land in SSM PS SecureString with the KMS alias `alias/aegis-staging-secrets`. This rule applies even though `config.yaml` is gitignored — the repo's "zero static credentials by design" posture draws the line at file type, not at git-tracked vs. local.

Both parameters live under the `/aegis/staging/qdrant-cloud/` prefix (the `qdrant-cloud` prefix names the managed product, matching the `grafana-cloud` convention in Runbook 006). Both use the CMK alias `alias/aegis-staging-secrets`, consistent with Grafana Cloud secrets and the existing External Secrets Operator IAM policy pattern.

As of ADR-028 (PR after Incident 33, 2026-04-25), the two `aws_ssm_parameter` SecureString resources are Terraform-managed in **`staging/secrets-persistent/qdrant.tf`** — moved out of `staging/observability/` to live in a baseline-tier layer that workload teardown cannot destroy (Incident 33 + 34 surfaced that `lifecycle.ignore_changes = [value]` does not protect against `destroy`). Terraform owns the resource declaration; the operator owns the value via `put-parameter`.

The K8s-side `kubectl_manifest.external_secret_qdrant_credentials` ExternalSecret CRD that consumes these values stays in `staging/observability/qdrant-external-secret.tf` — it requires the kubectl provider against the cluster, machinery already wired in observability (ADR-028 §ExternalSecret CRDs stay in observability).

The `aws ssm put-parameter` command is identical in both paths below; only the ordering relative to `terraform apply` differs.

### Path A — Fresh environment (Terraform-first adoption)

Use when the lab is being stood up from scratch and `qdrant_cloud.enabled: true` is about to land in `config/landing-zone.yaml` for the first time. Also the path to follow on **any cold-apply after a workload teardown** — the secrets-persistent layer survives teardown (the entire reason ADR-028 exists), but Qdrant cluster URL + api-key values that the operator put-parameter'd survive too. Path A applies fresh only when `qdrant_cloud.enabled` was just flipped to true.

1. The baseline-apply workflow runs `staging/secrets-persistent/` and creates two placeholder SSM SecureStrings with `value = "placeholder-operator-must-overwrite"`.
2. Overwrite both placeholders with real values from Part 2:

```bash
AWS_PROFILE=aegis-staging-admin aws ssm put-parameter \
  --region eu-central-1 \
  --name /aegis/staging/qdrant-cloud/cluster-url \
  --type SecureString \
  --key-id alias/aegis-staging-secrets \
  --overwrite \
  --value '<cluster URL from Part 2 step 1, including scheme + port, e.g. https://xyz.eu-central-1-0.aws.cloud.qdrant.io:6334>'

AWS_PROFILE=aegis-staging-admin aws ssm put-parameter \
  --region eu-central-1 \
  --name /aegis/staging/qdrant-cloud/api-key \
  --type SecureString \
  --key-id alias/aegis-staging-secrets \
  --overwrite \
  --value '<API key from Part 2 step 3>'
```

3. Next `terraform plan` shows zero drift — `ignore_changes = [value]` masks the placeholder vs. real-value divergence.

### Path B — Retrofit (values predate Terraform adoption)

Use when SSM PS values were `put-parameter`d manually BEFORE the secrets-persistent layer applied. A bare `terraform apply` with `qdrant_cloud.enabled: true` would otherwise fail with `ParameterAlreadyExists` — Terraform does not auto-adopt pre-existing AWS resources.

This path is rare in practice — for a fresh fork, follow Path A; for the lab's existing Bin-side state (post-Incident 33 teardown destroyed both values), there are no pre-existing AWS resources to retrofit. Path B remains documented for the edge case where a forker put-parameter'd values manually before discovering this runbook.

1. Put the creds in SSM PS via the Path A step-2 commands (skip if already done).
2. **Before** flipping `qdrant_cloud.enabled: true` and applying the secrets-persistent layer, import the two existing params into that layer's Terraform state:

```bash
export AWS_PROFILE=aegis-staging-admin
cd terraform/environments/staging/secrets-persistent
terraform init
terraform import 'aws_ssm_parameter.qdrant_cluster_url[0]' \
  /aegis/staging/qdrant-cloud/cluster-url
terraform import 'aws_ssm_parameter.qdrant_api_key[0]' \
  /aegis/staging/qdrant-cloud/api-key
```

3. Run `terraform plan` once. Confirm the plan shows **zero changes** (`ignore_changes` masks value drift; tags/description from the HCL are inherited on import). If plan shows a value-overwrite change, stop and investigate — the `lifecycle.ignore_changes` block is likely mis-configured.
4. Flip `qdrant_cloud.enabled: true` in `config/landing-zone.yaml`, sync the `LANDING_ZONE_CONFIG` GitHub Secret (`scripts/configure-github.sh`), then push — the next baseline-apply CI run reconciles the existing-now-managed resources without drift.

> Note: an `import { }` HCL block could be added to `staging/secrets-persistent/imports.tf` to make Path B declarative (analogous to the existing one for `bootstrap-token`). It is not currently included because the Bin-side state has no pre-existing values to retrofit and forker need is hypothetical. If a forker hits this path repeatedly, the import block is a 5-line follow-up PR.

### Verification

Either path — confirm both parameters are readable:

```bash
aws ssm get-parameter \
  --name /aegis/staging/qdrant-cloud/cluster-url \
  --with-decryption --query 'Parameter.Value' --output text
```

---

## Part 4 — Verify credential reachability

Before considering the onboarding done, prove the cluster is reachable with the API key. Use the REST endpoint on port 6333 for a simple health check (gRPC on 6334 is what the engine actually uses, but REST is easier for a shell-based smoke test — if REST auth works, gRPC auth with the same key will also work).

```bash
# Pull the URL from SSM PS, then curl /collections
CLUSTER_URL=$(aws ssm get-parameter \
  --name /aegis/staging/qdrant-cloud/cluster-url \
  --with-decryption --query 'Parameter.Value' --output text)
API_KEY=$(aws ssm get-parameter \
  --name /aegis/staging/qdrant-cloud/api-key \
  --with-decryption --query 'Parameter.Value' --output text)

# Replace the port with 6333 for REST if cluster-url is the :6334 gRPC form
REST_URL="${CLUSTER_URL/:6334/:6333}"

curl -s -o /dev/null -w "%{http_code}\n" \
  -H "api-key: ${API_KEY}" \
  "${REST_URL}/collections"
# Expected: 200 (empty collections list is fine — cluster is reachable and authz passed)
```

If 200, the credential chain is sound end-to-end. If not, see Troubleshooting.

---

## Part 5 — Terraform-managed state (interaction model)

As of ADR-028 (post-Incident 33), the Qdrant Cloud credential-plumbing path spans **two Terraservice layers** plus the aegis-core repo:

1. **SSM PS parameters — `staging/secrets-persistent/qdrant.tf`** (baseline-tier, never torn down). Two `aws_ssm_parameter` SecureString resources, one per credential, both count-gated on `local.qdrant_enabled` (from `config/landing-zone.yaml` → `qdrant_cloud.enabled`). Placeholder-value + `lifecycle.ignore_changes = [value]` pattern: Terraform owns the resource declaration, the operator owns the value via `put-parameter --overwrite`. Originally landed in `staging/observability/` (PR #146); migrated here by ADR-028 after Incident 33 destroyed both values during a workload teardown. See [Part 3](#part-3--stash-credentials-in-ssm-parameter-store) for the two ordering paths.

2. **ExternalSecret manifest — `staging/observability/qdrant-external-secret.tf`** (workload-tier). `kubectl_manifest.external_secret_qdrant_credentials` reconciles the two SSM params (read by path string, not via TF state) into K8s Secret `qdrant-credentials` in ns `aegis` at 1h refresh interval. Gated additionally on `local.platform_applied` so a cold-cycle first-apply (observability runs before the cluster exists, or without workloads) skips cleanly and lets the AWS-side resources still create.

3. **Engine Deployment env-vars — aegis-core repo** (not here). `QDRANT_URL` + `QDRANT_API_KEY` are wired via `envFrom` / `valueFrom: secretKeyRef` pulls of the reconciled K8s Secret in aegis-core's `apps/staging/aegis-engine/rollout.yaml` (PR #92). Pod restart (or `kubectl rollout restart deployment engine -n aegis`) picks up rotated keys; see [credential rotation below](#credential-rotation).

Why two ldz layers instead of one: `staging/secrets-persistent/` is excluded from `terraform-teardown-workload.yml` so SaaS-portal-issued values survive workload cycles. `staging/observability/` IS in the teardown matrix so the K8s-side ExternalSecret + observability stack tear down cleanly with the cluster. Apply ordering is enforced by the workflow split (baseline before workload). See [ADR-028](../decisions/028-persistent-saas-credential-isolation.md) §Decision and [Incident 34](../incidents.md#incident-34--lifecycleignore_changes-does-not-protect-against-destroy-2026-04-25) for the rationale.

Cross-repo references: [ldz #141](https://github.com/BinHsu/aegis-aws-landing-zone/issues/141) (Secret contract, closed 2026-04-24 by PR #146), [ADR-025](../decisions/025-qdrant-backend-cloud-free-tier.md) §"Platform work triggered on its arrival" (the trigger list this satisfies), [ADR-028](../decisions/028-persistent-saas-credential-isolation.md) (layer split rationale).

---

## Credential rotation

### API key — every 90 days

The rotation procedure is operator-driven even after Terraform adoption: Terraform declares the resource but delegates `value` via `lifecycle.ignore_changes = [value]`, so `put-parameter --overwrite` is the rotation lever.

1. Qdrant Cloud Portal → Cluster Detail → API Keys → **+ Create** a new key (name `engine-<YYYYMMDD>`, expiration 90 days, manage/write)
2. **COPY the new key** — shown only once
3. Overwrite the SSM parameter:

```bash
AWS_PROFILE=aegis-staging-admin aws ssm put-parameter \
  --region eu-central-1 \
  --name /aegis/staging/qdrant-cloud/api-key \
  --type SecureString \
  --key-id alias/aegis-staging-secrets \
  --overwrite \
  --value '<new key>'
```

4. **If the engine Deployment is running**: trigger a reload — either wait for External Secrets' refresh interval (≤1 hour) and then `kubectl rollout restart deployment engine -n aegis`, or force-refresh the ExternalSecret with `kubectl annotate externalsecret qdrant-credentials -n aegis force-sync=$(date +%s) --overwrite` and then restart the Deployment.

   If the cluster is not currently up (between cold-apply and teardown cycles, or before first cold-apply), rotation stops at the SSM PS overwrite. The `lifecycle.ignore_changes` block on the SSM parameter means the next `terraform apply` sees no drift. The next workload cold-apply + ExternalSecret reconcile picks up the rotated value automatically.

5. Qdrant Cloud Portal → Cluster Detail → API Keys → delete the **old** key. Confirm traffic has not degraded (pull a fresh `curl /collections` with the new key via Part 4).

6. Reset calendar reminder for 90 days.

### Cluster URL — rotates only on cluster re-creation

The URL is stable for the lifetime of a cluster. It changes only on cluster recreation (region migration, account migration). Treat cluster recreation as a full onboarding — return to Part 1.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `curl /collections` returns `401 Unauthorized` | API key wrong, expired, or sent under the wrong header | Confirm key matches what's in SSM PS (`aws ssm get-parameter ... --with-decryption`); confirm header is `api-key: <key>` or `Authorization: Bearer <key>`; if key recently rotated, confirm old key was not re-put by mistake |
| `curl /collections` returns `404 Not Found` | Wrong port (6333 vs 6334) or URL missing scheme | The REST endpoint is 6333, gRPC is 6334. curl over HTTPS needs an explicit `https://`. Check `$REST_URL` expansion |
| `curl /collections` returns `403 Forbidden` | API key permission level is read-only, but route requires manage | Create a new key with manage/write permission (Part 2 step 2); delete the over-restricted key |
| `aws ssm put-parameter` returns `AccessDenied` on `kms:Decrypt` or `ssm:PutParameter` | AWS_PROFILE not assumed the admin role, or CMK alias does not exist in this account/region | Re-run `aws sso login --sso-session aegis`; confirm `aws sts get-caller-identity` shows `aegis-staging-admin`; confirm `alias/aegis-staging-secrets` exists in `eu-central-1` via `aws kms describe-key --key-id alias/aegis-staging-secrets` |
| Free tier cluster creation offers only US regions | Free tier is region-restricted on Qdrant Cloud (ADR-025 §GDPR caveat) | Accept US residency for the non-PII lab corpus, or upgrade to paid tier + attach payment method and select `eu-central-1` |
| After cluster recreation, engine cannot connect | Old cluster URL still in SSM PS | `aws ssm put-parameter --overwrite` with the new URL; re-run Part 4 verify; if engine pod is running, restart it |

---

## Account / cluster teardown (permanent — not per-session)

Qdrant Cloud clusters are NOT torn down between sessions — the free tier costs $0 to keep idle, and the Taiwan corpus re-ingest cost (time, not dollars) is non-trivial. Tear down only when abandoning the lab permanently or when migrating to a new cluster.

Teardown order:

1. Flip `qdrant_cloud.enabled: false` in `config/landing-zone.yaml` (or remove the block entirely) and sync the `LANDING_ZONE_CONFIG` GitHub Secret. Push to `main`. The baseline-apply workflow plans the two `aws_ssm_parameter` resources in `staging/secrets-persistent/` to destruction on the `count = 0` gate, AND plans the ExternalSecret in `staging/observability/` (if `local.platform_applied`) to destruction on its own gate. This removes the ExternalSecret first (if the cluster is still up at this point) so the K8s Secret deletion is graceful before the SSM PS source goes away.

   > Note: this is the only correct path to destroy these resources. Running `terraform-teardown-workload.yml` does NOT touch `staging/secrets-persistent/` (by design — ADR-028 §Decision). To delete the SSM params, you must flip the config flag and re-run the baseline workflow.

2. Delete the Qdrant Cloud cluster: Portal → Clusters → your cluster → **Delete cluster**. **WARNING**: all ingested vectors are lost on cluster deletion — export collections to local files first if you need to preserve them. For the Taiwan corpus, re-ingest is a re-run of `engine seed --target=cloud` — non-trivial but not catastrophic.
3. Step 1 destroyed the SSM parameters via Terraform's count gate. If the SSM PS entries somehow survived (e.g., state-file divergence from destruction), clean up manually:

```bash
for param in cluster-url api-key; do
  aws ssm delete-parameter --name /aegis/staging/qdrant-cloud/$param 2>/dev/null || true
done
```

---

## Related

- [ADR-025](../decisions/025-qdrant-backend-cloud-free-tier.md) — Qdrant backend decision (Cloud free tier)
- [ADR-023](../decisions/023-observability-responsibility-model.md) — External Secrets + SSM PS pattern reused here
- [Runbook 006](006-grafana-cloud-onboarding.md) — sibling SaaS onboarding for Grafana Cloud; same credential-plumbing shape
