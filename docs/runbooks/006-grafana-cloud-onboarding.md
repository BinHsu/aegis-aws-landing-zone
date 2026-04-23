<!-- session-close-review: when lab operator needs a fresh Grafana Cloud stack, rotates any of the three tokens, or migrates to a new Grafana Cloud region -->
# 006. Grafana Cloud free tier — onboarding and token rotation

> **When to read this**: you are doing a first-time Grafana Cloud signup for this lab, rotating a bootstrap or downstream token, or migrating to a new Grafana Cloud stack. This is NOT a per-session runbook — per-session `terraform-apply-workload` flow does not touch Grafana Cloud onboarding once the bootstrap token is in SSM PS. Reading in full takes <5 minutes.

## When to use

- First-time signup for this lab (Bin or any forker)
- Bootstrap token rotation (every 30 days)
- Downstream token rotation (every 90 days)
- Migrating to a new Grafana Cloud stack (region change, account change)

Related: [ADR-022](../decisions/022-observability-backend-grafana-cloud.md) (backend decision), [ADR-023](../decisions/023-observability-responsibility-model.md) (responsibility model).

---

## Pre-flight

- AWS CLI + AWS SSO login to `aegis-staging` active (`aws sso login --sso-session aegis`; `export AWS_PROFILE=aegis-staging-admin`)
- Browser with Gmail available (account root will be bound to this email)
- 45–60 minutes for first-time setup; 10–15 minutes for rotation
- No payment method required for free tier
- Do NOT attach a credit card — keeps overage behavior on throttle, not auto-upgrade

---

## Part 1 — Sign up and create stack

1. Navigate to `https://grafana.com/signup`
2. Sign up with email. Note: this email is the account root and is difficult to change later. Lab uses `pcpunkhades@gmail.com`.
3. Most Grafana Cloud signup flows auto-create both an organization and a stack matching your account name (the lab's live signup on 2026-04-23 produced org `aegis` + stack slug `aegis`). Skip this step if you are happy with the auto-created org; otherwise manually create one (suggested name: `aegis-lab`).
4. Create stack — **skip if signup auto-created one you want to keep**. Otherwise:
   - Stack URL slug: your choice. Update `config/landing-zone.yaml` `grafana_cloud.org_slug` to match your **actual** slug — the `aegis-staging` example appearing elsewhere in this repo is a suggestion, not a contract. If the auto-created slug (typically equal to your org name) is fine, record that value and move on.
   - Region: `eu-central` (Frankfurt) — **REGION IS LOCKED once set**; changing requires a new stack and full re-ingest. Availability confirmed on free tier 2026-04-23.
5. Record stack endpoints (needed later). Find them under Portal → Stacks → your stack → Details:
   - Grafana URL: `https://<slug>.grafana.net`
   - Mimir URL: `https://prometheus-prod-<N>-<mimir-region>-<N>.grafana.net/api/prom`
   - Loki URL: (informational; not yet used)

   Note: the Mimir backend region (`<mimir-region>`, e.g. `eu-west`) can differ from the stack region (`eu-central`) selected in step 4 — this is historical Grafana Cloud behavior where Mimir/Loki/Tempo backends are provisioned on their own regional fleets and are not strictly co-located with the Grafana front-end. Both `<N>` placeholders are auto-assigned during stack creation and are visible in the Details page. Do NOT guess these — copy them verbatim.

---

## Part 2 — Create bootstrap token (the ONLY manual token)

This is the single manual step. Terraform provisions all downstream tokens after this.

1. Open `https://grafana.com` Portal → your org → Access Policies → Create access policy
2. Policy settings:
   - Name: `terraform-bootstrap`
   - Display name: `Terraform bootstrap — provisions downstream tokens`
   - Realm: this stack only (NOT org-wide)
   - Scopes (check these, uncheck everything else):
     - `accesspolicies:read`
     - `accesspolicies:write`
     - `stacks:read`
     - `stack-service-accounts:write`
     - `stack-api-keys:write`
   - Note on missing `:read` rows: Grafana Cloud Portal UI (verified 2026-04-23) offers only `:write` for `stack-service-accounts` and `stack-api-keys` — no separate `:read` checkbox exists. This follows Grafana's convention that write-scopes for create-mostly resources implicitly grant the read needed by the Terraform provider to list existing items before create. If a future Terraform apply fails with 403 on SA/API-key list operations, widen the policy with whatever additional scope the error references and amend this runbook.
   - Do NOT grant: `billing:*`, `stacks:write`, `stacks:delete` — these are the "delete the stack" scopes
3. Click "Add token":
   - Name: `bootstrap-<YYYYMMDD>`
   - Expires: 30 days from today (set a calendar reminder for rotation)
4. **COPY THE TOKEN** — shown only once
5. Store in SSM Parameter Store:

```bash
AWS_PROFILE=aegis-staging-admin aws ssm put-parameter \
  --region eu-central-1 \
  --name /aegis/staging/grafana-cloud/bootstrap-token \
  --type SecureString \
  --key-id alias/aegis-staging-secrets \
  --value '<token from step 4>'
```

---

## Part 3 — Create break-glass admin user

Free tier does NOT support SAML. If the `grafana-operator` service account token breaks, a human must recover manually. This admin user is that recovery path.

The goal is **any human-level OAuth login that is independent of service-account tokens**. Which OAuth provider you use is secondary.

- **If you signed up via Google or GitHub OAuth at Part 1**: you already have a human-level OAuth path — your signup identity IS the break-glass. Verify once by opening the workspace URL in a private window and completing the OAuth flow from scratch to confirm it works independently of any in-progress session. Part 3 is effectively complete after this verification (no second user needed for a single-operator lab).
- **If you signed up via email + password**: add a secondary OAuth identity (Google or GitHub) now — email+password alone is not an acceptable break-glass because it collapses into a single password-manager dependency.
- **Belt-and-suspenders option (enterprise / multi-operator scope)**: even if signed up via OAuth, invite a second independent OAuth identity so recovery does not depend on a single provider account (e.g. GitHub SSO + Google OAuth as orthogonal recovery paths). Overkill for a single-operator portfolio lab; warranted for production.

Steps for adding a secondary OAuth identity (only if the signup path did not cover it):

1. Open the workspace URL: `https://<stack-slug>.grafana.net`
2. Navigate: Administration → Users and access → Users → Invite new user
3. Fill in:
   - Email: the operator's Google- or GitHub-linked email
   - Role: Admin
4. User receives invitation email → accept → "Sign in with Google" (or "Sign in with GitHub")
5. Verify login works BEFORE proceeding — confirm browser-based admin access, independent of any machine token

If SAML SSO (AWS IAM Identity Center integration) is needed: upgrade to Grafana Cloud Pro. See [ADR-022](../decisions/022-observability-backend-grafana-cloud.md) §Known limitations and [ADR-021](../decisions/021-observability-scaling-path.md) rung transitions.

---

## Part 4 — Terraform provisions downstream tokens (via CI)

Once the bootstrap token is in SSM PS, Terraform takes over. No further manual token creation. Apply goes through the CI workflow — **do NOT run `terraform apply` locally**. Local apply is break-glass only (see [`docs/principles/break-glass-apply.md`](../principles/break-glass-apply.md)); the standard path is the dispatched workflow, which assumes the GitHub OIDC role and records an audit trail.

Per PR #128, the `apply-observability` job in `.github/workflows/terraform-apply-workload.yml` applies the observability layer as the last stage of the standard cold-apply pipeline:

```bash
gh workflow run terraform-apply-workload.yml -f env=staging
gh run watch   # approve when GitHub prompts
```

If you want to smoke the observability layer in isolation (e.g. right after creating the bootstrap token, before a full workload cycle), re-run the same command — the earlier layers (`apply-network`, `apply-platform`, `apply-workloads`) are idempotent and the observability layer is gated on `observability_enabled` in config, so applying with no `grafana_cloud` block in `config/landing-zone.yaml` plans to zero resources.

On success, the `apply-observability` job creates (via the `grafana/grafana` Terraform provider):

- Cloud Access Policy `aegis-staging-alloy` (scopes: `metrics:write`, `logs:write`) → token stored at `/aegis/staging/grafana-cloud/alloy-token`
- Grafana Service Account `grafana-operator` (role: Admin) → token stored at `/aegis/staging/grafana-cloud/grafana-operator-token`

If the `apply-observability` job fails at the `grafana_*` resources:

- Check the bootstrap token has not expired (30-day limit)
- Check scope completeness (see Part 2 step 2)
- Re-dispatch the workflow after fixing

---

## Part 5 — Verify scope isolation

One-time sanity check that tokens are scope-limited as intended.

**Before running the curl commands below**, find your stack slug and Mimir URL from Grafana Cloud Portal → Stacks → your stack → Details. Substitute them into the `<stack-slug>` and `<N>` placeholders (the two `<N>` values in the Mimir URL are both auto-assigned by Grafana Cloud and differ from the stack region; see Part 1 step 5).

Alloy token should NOT work on Grafana admin API:

```bash
ALLOY_TOKEN=$(aws ssm get-parameter \
  --name /aegis/staging/grafana-cloud/alloy-token \
  --with-decryption --query 'Parameter.Value' --output text)

curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $ALLOY_TOKEN" \
  https://<stack-slug>.grafana.net/api/dashboards/home
# Expected: 401 (correct — Alloy has metrics scope, not admin scope)
```

`grafana-operator` token should NOT work on Mimir ingestion:

```bash
GO_TOKEN=$(aws ssm get-parameter \
  --name /aegis/staging/grafana-cloud/grafana-operator-token \
  --with-decryption --query 'Parameter.Value' --output text)

curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $GO_TOKEN" \
  -X POST https://prometheus-prod-<N>-eu-west-<N>.grafana.net/api/prom/push
# Expected: 401 (correct — grafana-operator has stack admin, not metrics:write)
```

If either test returns 2xx, scopes are too broad — regenerate the over-scoped token.

---

## Part 6 — Hand off to terraform-apply-workload

Per-environment cold-apply proceeds normally:

```bash
gh workflow run terraform-apply-workload.yml -f env=staging
```

External Secrets Operator (installed in the platform layer) pulls `alloy` and `grafana-operator` tokens from SSM PS into K8s Secrets. Alloy and grafana-operator pods mount these Secrets.

---

## Token rotation

### Bootstrap token — every 30 days

1. Portal → Access Policies → `terraform-bootstrap` → Add token (new token; keep old token for 24h overlap)
2. Update the SSM parameter with the new token value
3. Re-run `terraform apply` in the observability layer — confirms the new token works
4. Portal → delete the old bootstrap token
5. Reset calendar reminder for 30 days

### Downstream tokens (alloy, grafana-operator) — every 90 days

Change is Terraform-driven:

1. Edit `terraform/environments/staging/observability/` — bump `expires_at` on `grafana_cloud_access_policy_token.alloy` and `grafana_service_account_token.grafana_operator`
2. `terraform apply` — generates new tokens, writes to SSM PS, deletes old tokens
3. External Secrets picks up the new values within its refresh interval (default 1 hour)
4. Alloy and grafana-operator pods continue running — Secret change triggers reload on next refresh

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Alloy logs `401 Unauthorized` on remote_write | `alloy-token` expired or wrong scope | Rotate per Part 4 downstream procedure; verify scope per Part 5 |
| Alloy logs `429 rate limit` | Active series over 10k cap | Run cardinality audit (Alloy `/debug/prometheus/self`); adjust relabel rules per [ADR-022](../decisions/022-observability-backend-grafana-cloud.md) §Cardinality |
| grafana-operator reconcile errors with `forbidden` | `grafana-operator-token` expired or lost admin role | Check SA still has Admin role in workspace; rotate token if needed |
| Terraform plan fails at `grafana_*` resources | Bootstrap token expired | Regenerate bootstrap per Part 2; update SSM; re-plan |
| Human cannot log in via Google OAuth | User not invited or role not assigned | Check Administration → Users; re-invite with Admin role |

---

## Stack teardown (permanent — not per-session)

When abandoning this lab permanently (NOT the per-session workload teardown):

1. Run pre-teardown CRD cleanup per [ADR-022](../decisions/022-observability-backend-grafana-cloud.md) §Teardown to avoid Grafana Cloud orphans
2. Delete the Grafana Cloud stack: Portal → stack → delete
3. Delete SSM parameters:

```bash
for param in bootstrap-token alloy-token grafana-operator-token team-webhooks-slack-platform team-webhooks-slack-aegis; do
  aws ssm delete-parameter --name /aegis/staging/grafana-cloud/$param
done
```

4. Remove the `grafana_cloud` block from `config/landing-zone.yaml`
5. **WARNING**: all historical metrics are lost; export dashboards to JSON first if desired

---

## Related

- [ADR-022](../decisions/022-observability-backend-grafana-cloud.md) — observability backend decision (Grafana Cloud free tier)
- [ADR-023](../decisions/023-observability-responsibility-model.md) — observability responsibility model (what lives where)
- [ADR-021](../decisions/021-observability-scaling-path.md) (amended) — scaling ladder; rung transitions trigger migration beyond free tier
