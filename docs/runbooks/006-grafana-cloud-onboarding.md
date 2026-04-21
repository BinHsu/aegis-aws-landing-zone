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
3. Create organization — suggested name: `aegis-lab`
4. Create stack:
   - Stack URL slug: `aegis-staging` (must match `config/landing-zone.yaml` `grafana_cloud.org_slug`)
   - Region: `eu-central` (Frankfurt) — **REGION IS LOCKED once set**; changing requires a new stack and full re-ingest
5. Record stack endpoints (needed later):
   - Grafana URL: `https://<slug>.grafana.net`
   - Mimir URL: `https://prometheus-prod-<N>-eu-west-<N>.grafana.net/api/prom`
   - Loki URL: (informational; not yet used)

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
     - `stack-service-accounts:read`
     - `stack-service-accounts:write`
     - `stack-api-keys:write`
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

Auth options on free tier (pick one — Google OAuth recommended):

- Google OAuth (recommended — aligns with lab operator's existing Gmail)
- GitHub OAuth
- Email + password (last resort; requires password manager)

Steps (Google OAuth path):

1. Open the workspace URL: `https://<stack-slug>.grafana.net`
2. Navigate: Administration → Users and access → Users → Invite new user
3. Fill in:
   - Email: operator's Gmail
   - Role: Admin
4. User receives invitation email → accept → "Sign in with Google"
5. Verify login works BEFORE proceeding — confirm browser-based admin access, independent of any machine token

If SAML SSO (AWS IAM Identity Center integration) is needed: upgrade to Grafana Cloud Pro. See [ADR-022](../decisions/022-observability-backend-grafana-cloud.md) §Known limitations and [ADR-021](../decisions/021-observability-scaling-path.md) rung transitions.

---

## Part 4 — Terraform provisions downstream tokens

Once the bootstrap token is in SSM PS, Terraform takes over. No further manual token creation.

```bash
cd terraform/environments/staging/observability
terraform init
terraform apply
```

This creates (via the `grafana/grafana` Terraform provider):

- Cloud Access Policy `aegis-staging-alloy` (scopes: `metrics:write`, `logs:write`) → token stored at `/aegis/staging/grafana-cloud/alloy-token`
- Grafana Service Account `grafana-operator` (role: Admin) → token stored at `/aegis/staging/grafana-cloud/grafana-operator-token`

If Terraform fails at the `grafana_*` resources:

- Check the bootstrap token has not expired (30-day limit)
- Check scope completeness (see Part 2 step 2)
- Re-run after fixing

---

## Part 5 — Verify scope isolation

One-time sanity check that tokens are scope-limited as intended.

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
