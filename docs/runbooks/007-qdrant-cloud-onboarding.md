<!-- session-close-review: when lab operator needs a fresh Qdrant Cloud cluster, rotates the API key, or the aegis-core Secret-contract cross-repo issue arrives and platform wiring moves from manual SSM PS puts to Terraform-managed resources -->
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
- GDPR caveat acknowledged: free tier cluster placement is effectively US-region on Qdrant Cloud today. The lab's corpus is non-PII Taiwan documentation by design (see [ADR-025](../decisions/025-qdrant-backend-cloud-free-tier.md) §GDPR region caveat). If your scope ever expands beyond the non-PII corpus, migrate to the paid tier's `eu-central-1` selector before ingesting.

---

## Part 1 — Sign up and create cluster

1. Navigate to `https://cloud.qdrant.io/signup`
2. Sign up with Gmail or GitHub OAuth. Note: this account is the org root and is difficult to change later. Lab uses `pcpunkhades@gmail.com`.
3. Accept any Terms / DPA prompts — free tier runs on Qdrant Labs' managed infrastructure; no additional contract is required.
4. Navigate to the Cloud Dashboard → **Clusters** → click **+ Create**
5. Create cluster:
   - Tier: **Free**
   - Cloud provider: **AWS** (Qdrant Cloud also offers GCP and Azure; AWS aligns with the lab's existing posture)
   - Region: the **free tier offers a limited set of regions** (see [ADR-025](../decisions/025-qdrant-backend-cloud-free-tier.md) §GDPR region caveat — EU regions may not be offered on free tier; a US region is expected). Pick the closest option available; do NOT upgrade to paid purely for region choice unless the corpus scope has changed to include PII.
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

## Part 3 — Stash credentials in SSM Parameter Store (manual, pre-Terraform)

**IMPORTANT**: per [ADR-025](../decisions/025-qdrant-backend-cloud-free-tier.md) §"Landing-zone implementation is deferred pending aegis-core Secret-contract issue", this repo has intentionally NOT yet shipped Terraform `aws_ssm_parameter` resources for the Qdrant Cloud credentials. The Secret shape (key names, env-var mappings, extra config like collection name / embedding dimension / distance metric) is aegis-core's call and will arrive as a cross-repo issue.

Until that issue lands and the corresponding platform PR merges, you must manually put the two parameters to SSM PS. Both parameters live under the `/aegis/staging/qdrant-cloud/` prefix (the `qdrant-cloud` prefix names the managed product, matching the `grafana-cloud` convention in Runbook 006).

```bash
# Cluster URL (not a secret in the strictest sense, but kept as SecureString
# to avoid mixing parameter tiers in the same namespace)
AWS_PROFILE=aegis-staging-admin aws ssm put-parameter \
  --region eu-central-1 \
  --name /aegis/staging/qdrant-cloud/cluster-url \
  --type SecureString \
  --key-id alias/aegis-staging-secrets \
  --value '<cluster URL from Part 2 step 1, including scheme + port, e.g. https://xyz.us-east-1.aws.cloud.qdrant.io:6334>'

# API key
AWS_PROFILE=aegis-staging-admin aws ssm put-parameter \
  --region eu-central-1 \
  --name /aegis/staging/qdrant-cloud/api-key \
  --type SecureString \
  --key-id alias/aegis-staging-secrets \
  --value '<API key from Part 2 step 3>'
```

Both parameters use the same CMK alias (`alias/aegis-staging-secrets`) as the Grafana Cloud secrets, for consistency with the existing External Secrets Operator IAM policy pattern.

Verify both parameters are readable:

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

## Part 5 — Future state: when TF scaffolding lands

When aegis-core files the cross-repo Secret-contract issue and the corresponding platform PR merges, three things change:

1. **Terraform takes over the SSM PS parameters**. Two `aws_ssm_parameter` SecureString resources (at `/aegis/<env>/qdrant-cloud/cluster-url` and `/aegis/<env>/qdrant-cloud/api-key`) land in either `staging/observability/tokens.tf` (extension) or a new `staging/workloads/qdrant.tf`, matching the placeholder-value + `lifecycle.ignore_changes = [value]` pattern already used for `team-webhooks-slack-aegis`. This means the operator-created values **persist** — Terraform will not overwrite them on first plan, because the `ignore_changes` block treats the live value as authoritative.

   On the first apply after the TF resources land, double-check `terraform plan` output shows **no destructive change** to the parameter's value. If it does, stop and investigate — the `lifecycle.ignore_changes` block is likely missing or misconfigured.

2. **ExternalSecret manifest is added** to the `aegis` namespace. It reconciles `qdrant-credentials` K8s Secret from the two SSM PS parameters on the External Secrets refresh interval (default 1 hour).

3. **Engine Deployment env-vars are wired** (in aegis-core, not here). `QDRANT_URL` and `QDRANT_API_KEY` become `envFrom` / `valueFrom: secretKeyRef` pulls of the reconciled Secret. Pod restart (or a `kubectl rollout restart deployment engine`) is what picks up a rotated key — until the Deployment wiring exists, rotation is purely a manual SSM re-put.

See [ADR-025](../decisions/025-qdrant-backend-cloud-free-tier.md) §"Platform work triggered on its arrival" for the full trigger list.

---

## Credential rotation

### API key — every 90 days

Until the TF scaffolding in Part 5 lands, rotation is manual:

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

   Note: before the TF scaffolding and ExternalSecret land, there is no reload path — there is no live engine pod consuming the key yet. Rotation stops at the SSM PS overwrite.

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

1. If the platform-side Terraform scaffolding in Part 5 has landed, first `terraform state rm` or destroy the `aws_ssm_parameter.qdrant_cloud_*` resources (check the exact path after PR lands). Do this BEFORE deleting the cluster, so the downstream ExternalSecret does not flap on missing parameters.
2. Delete the Qdrant Cloud cluster: Portal → Clusters → your cluster → **Delete cluster**. Historical vector data is lost — export collections to local files first if you need to preserve them.
3. Delete SSM parameters:

```bash
for param in cluster-url api-key; do
  aws ssm delete-parameter --name /aegis/staging/qdrant-cloud/$param
done
```

4. If the ADR-025 implementation PR has landed, remove the `qdrant_cloud` block from `config/landing-zone.yaml` (if one exists) so the TF layer plans to zero resources on next apply.
5. **WARNING**: all ingested vectors are lost on cluster deletion. For the Taiwan corpus, re-ingest is a re-run of `engine seed --target=cloud` — non-trivial but not catastrophic.

---

## Related

- [ADR-025](../decisions/025-qdrant-backend-cloud-free-tier.md) — Qdrant backend decision (Cloud free tier)
- [ADR-023](../decisions/023-observability-responsibility-model.md) — External Secrets + SSM PS pattern reused here
- [Runbook 006](006-grafana-cloud-onboarding.md) — sibling SaaS onboarding for Grafana Cloud; same credential-plumbing shape
