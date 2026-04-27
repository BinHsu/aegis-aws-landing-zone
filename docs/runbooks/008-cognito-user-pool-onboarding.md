<!-- session-close-review: when lab operator provisions the Cognito user pool for the first time, creates a new admin user, rotates a user's password, or adds an IdP federation later -->
# 008. Cognito User Pool — onboarding and first-user creation

> **When to read this**: you are doing a first-time Cognito User Pool provisioning for this lab, inviting the first admin user into a newly-created pool, rotating an existing user's password, or planning to add Google / GitHub federation. This is NOT a per-session runbook — the Cognito User Pool is baseline-tier infrastructure. Once provisioned, it persists across workload-tier teardown cycles. Reading in full takes <5 minutes.

## When to use

- First-time Cognito User Pool provisioning for this lab (Bin or any forker)
- Creating the first admin user after `terraform apply` on `staging/auth/` lands
- Rotating an operator's password
- Adding a new admin user at a later date
- Adding Google / GitHub / SAML IdP federation (future — this runbook anchors the flow; federation-specific steps are appended when the ADR-026 amendment for federation lands)

Related: [ADR-026](../decisions/026-cognito-auth-user-pool.md) (backend decision, including the deferred-implementation gate), [ADR-022](../decisions/022-observability-backend-grafana-cloud.md) and [ADR-023](../decisions/023-observability-responsibility-model.md) (External Secrets + SSM PS pattern reused here), [Runbook 006](006-grafana-cloud-onboarding.md) and [Runbook 007](007-qdrant-cloud-onboarding.md) (sibling SaaS onboarding shape).

> **Forker note**: shell snippets below are written against this lab's specific values — operator email and `staging.binhsu.org` domain. When applying yourself, substitute (a) the operator email you used at SSO bootstrap (Runbook 001), and (b) your `domain.name` from `config/landing-zone.yaml` everywhere you see `binhsu.org`.

---

## Pre-flight

- AWS CLI + AWS SSO login to `aegis-staging` active (`aws sso login --sso-session aegis`; `export AWS_PROFILE=aegis-staging-admin`)
- Confirm ADR-026 reflects the pinned callback / logout URLs (aegis-core #76 confirmation 2026-04-23). ADR-026 is Accepted once the amendment lands; until then, Partially Accepted is fine for apply because the URL values are now final.
- Confirm `config/landing-zone.yaml` has a populated `cognito:` block. Callback/logout URLs are `https://aegis-app.staging.binhsu.org/auth/callback` and `https://aegis-app.staging.binhsu.org/` (aegis-core-confirmed). If the block is absent, the layer plans zero resources — a clean no-op apply is still the right first step to confirm workflow + plumbing.
- Confirm aegis-core's SPA auth scaffold is merged on `main` (aegis-core #78, #79, #80 all landed 2026-04-23). Without these, the Hosted UI login verification in Part 3 cannot be completed end-to-end — you can still verify steps 1–4, but the post-callback token exchange will 404 in the browser.
- Confirm the `aegis` namespace exists in the target cluster (apply `staging/workloads` first if the current cold-apply cycle has not reached that stage yet).
- A browser with the operator's Google account available (for Hosted UI login testing in Part 3).
- 30–45 minutes for first-time provisioning + user creation + smoke tests; 5–10 minutes for password rotation alone.

---

## Part 1 — Terraform apply on `staging/auth/`

Per [CLAUDE.md § Cost Guardrails](../../CLAUDE.md#cost-guardrails), baseline-tier layers auto-apply on merge to `main`. `staging/auth/` is a baseline-tier layer (it does not incur hourly cost once provisioned — Cognito User Pool free tier is 50k MAU permanent, see [ADR-026](../decisions/026-cognito-auth-user-pool.md) §Consequences).

The layer auto-applies when a PR that touches `terraform/environments/staging/auth/**` or `config/**` merges to `main`:

1. Merging triggers `terraform-apply-baseline.yml` which runs plan + apply on baseline-tier layers. Watch the run: `gh run list --workflow=terraform-apply-baseline.yml` + `gh run view <id> --log-failed` if the auth row fails.

2. **First-cold-cycle expected failure**: on a brand-new environment where `staging/workloads` has not been applied yet, the `kubectl_manifest.external_secret_cognito_config` step fails with `namespaces "aegis" not found`. The AWS-side resources (user pool, app client, domain, SSM parameters, IAM role) apply cleanly regardless. The operator applies `staging/workloads` via `gh workflow run terraform-apply-workload.yml -f env=staging`, then re-dispatches baseline via `gh workflow run terraform-apply-baseline.yml` to land the ExternalSecret. This is the same mitigation shape as `staging/observability` — not a bug.

3. Do **not** run `terraform apply` locally unless this is a break-glass scenario per [`docs/principles/break-glass-apply.md`](../principles/break-glass-apply.md). Local applies bypass the audit trail and skip the OIDC-assumed role path.

4. On success, confirm the five SSM parameters exist and carry non-empty values:

   ```bash
   for key in user-pool-id user-pool-arn app-client-id issuer-url hosted-ui-domain; do
     aws ssm get-parameter \
       --name /aegis/staging/cognito/$key \
       --with-decryption --query 'Parameter.Value' --output text
   done
   ```

   All five must print non-empty strings. The issuer URL format is `https://cognito-idp.eu-central-1.amazonaws.com/<user-pool-id>` — if it does not match this shape, the `issuer-url` was likely written from the wrong Cognito attribute; check `outputs.tf` + the `aws_ssm_parameter.issuer_url` value expression.

4. Confirm the `cognito-config` ExternalSecret has reconciled into a K8s Secret:

   ```bash
   kubectl get externalsecret cognito-config -n aegis -o yaml
   kubectl get secret cognito-config -n aegis -o jsonpath='{.data}' | jq 'keys'
   # Expected keys: ["COGNITO_APP_CLIENT_ID", "COGNITO_ISSUER_URL", "COGNITO_USER_POOL_ID"]
   ```

   If the ExternalSecret status shows `SecretSyncedError`, check IAM policy scope on the ESO role (it needs `ssm:GetParameter` + `kms:Decrypt` on `/aegis/staging/cognito/*` and `alias/aegis-staging-secrets` — same as Grafana Cloud).

---

## Part 2 — Create the first admin user

Cognito User Pools are provisioned empty. Per ADR-026 §Decision, MVP self-signup is **disabled**; the operator invites users via `admin-create-user`.

The canonical first user is the operator's email. Subsequent users follow the same recipe — swap in the new user's email and pick a strong temporary password.

1. Pull the user pool ID from SSM PS (avoids hand-copying from the Terraform output):

   ```bash
   USER_POOL_ID=$(aws ssm get-parameter \
     --name /aegis/staging/cognito/user-pool-id \
     --with-decryption --query 'Parameter.Value' --output text)
   echo "$USER_POOL_ID"
   ```

2. Create the user with a temporary password. Cognito requires the user to reset this on first login; we then override immediately in step 3 so the lab operator can log in without the reset flow.

   ```bash
   aws cognito-idp admin-create-user \
     --region eu-central-1 \
     --user-pool-id "$USER_POOL_ID" \
     --username pcpunkhades@gmail.com \
     --user-attributes Name=email,Value=pcpunkhades@gmail.com \
                       Name=email_verified,Value=true \
                       Name=custom:tenant_id,Value=aegis-default \
     --temporary-password '<strong temp password>' \
     --message-action SUPPRESS
   ```

   - `email_verified=true` is set explicitly so the operator does not have to complete the email-verification challenge before first login. For non-operator invitees, leave `email_verified` unset and let Cognito send the verification mail.
   - `custom:tenant_id=aegis-default` is set at creation time because the attribute is declared immutable in ADR-026 §Decision — it cannot be changed on the user later without a full delete + recreate. Pick the right tenant value the first time.
   - `--message-action SUPPRESS` prevents Cognito from sending the "temporary password" email. The operator knows the password (just set it); an email would leak it into inbox history for no benefit.

3. Immediately promote the temporary password to a permanent password:

   ```bash
   aws cognito-idp admin-set-user-password \
     --region eu-central-1 \
     --user-pool-id "$USER_POOL_ID" \
     --username pcpunkhades@gmail.com \
     --password '<your real password>' \
     --permanent
   ```

   The `--permanent` flag skips the first-login reset challenge. This is the operator-onboarding shortcut; for invited users you would omit `--permanent` and let them complete the reset via Hosted UI.

4. Verify user state:

   ```bash
   aws cognito-idp admin-get-user \
     --region eu-central-1 \
     --user-pool-id "$USER_POOL_ID" \
     --username pcpunkhades@gmail.com
   ```

   Expected: `UserStatus: CONFIRMED`, `Enabled: true`, and `UserAttributes` listing `email`, `email_verified: true`, `custom:tenant_id: aegis-default`, `sub: <uuid>`. If `UserStatus` shows `FORCE_CHANGE_PASSWORD`, step 3 did not apply — re-run with `--permanent`.

---

## Part 3 — Hosted UI login verification

At this point the user exists in Cognito but has never completed an OAuth flow. The goal of this part is to prove the Hosted UI → app client → callback chain works end-to-end **from a browser**, independent of the gateway.

Pull the three values you need (all retrievable from SSM PS, so the runbook is copy-paste reproducible):

```bash
APP_CLIENT_ID=$(aws ssm get-parameter \
  --name /aegis/staging/cognito/app-client-id \
  --with-decryption --query 'Parameter.Value' --output text)

COGNITO_DOMAIN=$(aws ssm get-parameter \
  --name /aegis/staging/cognito/hosted-ui-domain \
  --with-decryption --query 'Parameter.Value' --output text)
# Expected: aegis-staging.auth.eu-central-1.amazoncognito.com

# Callback URL — aegis-core-confirmed value from aegis-core #76 (2026-04-23).
# Must match one of the app client's registered callback_urls exactly
# (scheme, host, path, no trailing slash drift).
CALLBACK_URL='https://aegis-app.staging.binhsu.org/auth/callback'
```

Construct the Hosted UI login URL:

```
https://${COGNITO_DOMAIN}/login?client_id=${APP_CLIENT_ID}&response_type=code&scope=openid+profile+email&redirect_uri=${CALLBACK_URL}
```

Open it in a browser. Expected flow:

1. Hosted UI login page renders with the app client's display name.
2. Enter `pcpunkhades@gmail.com` + the permanent password set in Part 2 step 3.
3. If MFA is configured (`mfa_configuration: OPTIONAL` or `ON` in config.yaml), complete the MFA challenge. For lab default `mfa_configuration: OFF`, skip.
4. Browser redirects to `${CALLBACK_URL}?code=<authorization-code>&state=...`. The code is single-use and short-lived (~5 minutes).

What the operator is verifying: (a) credentials work, (b) MFA prompts behave as configured, (c) the authorization code is returned on redirect. This is purely the Hosted UI → Cognito → browser half of the flow; the SPA's token exchange against `/oauth2/token` happens next in Part 4 (or, in production, in the SPA's `/auth/callback` handler).

**If the redirect returns `400 redirect_mismatch`**: the `redirect_uri` you passed does not exactly match any registered `callback_urls` on the app client. Check Terraform state against the URL you queried; fix one or the other, `terraform apply`, retry.

---

## Part 4 — Token smoke test

This is the operator-side check that Cognito-issued tokens validate correctly against the JWKS endpoint — i.e. the same validation path the gateway will run on every request.

Prerequisite: you have an authorization code from Part 4 step 4. Exchange it for tokens:

```bash
# Substitute the authorization code from the browser redirect.
CODE='<code from Part 3 step 4>'

# Callback must match Part 3 exactly — aegis-core-confirmed on aegis-core #76.
CALLBACK_URL='https://aegis-app.staging.binhsu.org/auth/callback'

TOKEN_RESPONSE=$(curl -s -X POST \
  "https://${COGNITO_DOMAIN}/oauth2/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=authorization_code" \
  -d "client_id=${APP_CLIENT_ID}" \
  -d "code=${CODE}" \
  -d "redirect_uri=${CALLBACK_URL}")

echo "$TOKEN_RESPONSE" | jq .
# Expected keys: id_token, access_token, refresh_token, expires_in (3600), token_type ("Bearer")
```

Extract the ID token and inspect it:

```bash
ID_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r .id_token)

# Decode the header and payload without signature verification first (sanity check).
echo "$ID_TOKEN" | cut -d. -f1 | base64 --decode 2>/dev/null | jq .
# Expected header: {"kid": "<key-id>", "alg": "RS256"}

echo "$ID_TOKEN" | cut -d. -f2 | base64 --decode 2>/dev/null | jq .
# Expected payload: sub, email, custom:tenant_id, aud (= APP_CLIENT_ID),
#   iss (= https://cognito-idp.eu-central-1.amazonaws.com/<USER_POOL_ID>),
#   token_use ("id"), exp, iat.
```

Verify the signature against Cognito's JWKS. The JWKS URL is the issuer URL + `/.well-known/jwks.json`:

```bash
ISSUER_URL=$(aws ssm get-parameter \
  --name /aegis/staging/cognito/issuer-url \
  --with-decryption --query 'Parameter.Value' --output text)

JWKS=$(curl -s "${ISSUER_URL}/.well-known/jwks.json")
echo "$JWKS" | jq '.keys | map({kid, kty, alg, use})'
# Expected: two keys listed (Cognito rotates between two signing keys), both "alg": "RS256", "use": "sig".
```

If you have the `mikefarah/yq` or a dedicated JWT CLI available, verify the signature directly. The minimal path via `openssl` is:

```bash
# Pull the kid from the ID token header, then find the matching JWK and
# reconstruct a PEM public key (Cognito returns RSA n/e — convert via a small
# helper script or an online JWK-to-PEM tool; the Go gateway does this in its
# middleware on startup and caches the result).
```

What the operator is verifying: (a) the `kid` in the ID token header matches one of the two `kid`s in the JWKS response, (b) the `iss` claim matches the SSM `issuer-url` exactly, (c) `aud` matches the app client ID, (d) `custom:tenant_id` is present and carries the expected value from Part 2. The gateway's middleware will do exactly these checks on every request; if the manual walk passes, the gateway-side validation should too.

**If `kid` in the token is not found in JWKS**: Cognito just rotated keys mid-flight. Wait 5 minutes, re-fetch JWKS, retry. If the mismatch persists, the gateway's JWKS cache may need a manual refresh — see Troubleshooting.

---

## Credential / user rotation

### Rotating an existing user's password

```bash
aws cognito-idp admin-set-user-password \
  --region eu-central-1 \
  --user-pool-id "$USER_POOL_ID" \
  --username pcpunkhades@gmail.com \
  --password '<new password>' \
  --permanent
```

Existing refresh tokens remain valid until their 30-day expiry unless you explicitly revoke them. To force logout on password change, call `admin-user-global-sign-out` immediately after:

```bash
aws cognito-idp admin-user-global-sign-out \
  --region eu-central-1 \
  --user-pool-id "$USER_POOL_ID" \
  --username pcpunkhades@gmail.com
```

### Immutable attribute constraint

`custom:tenant_id` is declared **immutable** at user-pool creation per ADR-026 §Decision. This is a deliberate choice — the attribute carries tenant identity into every ID token, and making it mutable would mean a compromised user could change their claimed tenant. The consequence is that changing a user's `custom:tenant_id` requires a full delete + recreate of the user:

```bash
# Delete:
aws cognito-idp admin-delete-user \
  --region eu-central-1 \
  --user-pool-id "$USER_POOL_ID" \
  --username <username>

# Recreate with Part 2's recipe, using the new tenant value.
```

If immutability proves operationally expensive (e.g. tenant structure changes often), the correct response is an ADR-026 amendment that changes the attribute to mutable plus a plan for backfilling the security model that immutability was providing — not a quiet schema change.

### Rotating the app client secret

The app client in `staging/auth/` is configured as a **public client** (no secret) because it serves a browser SPA per ADR-026 §Decision. There is no secret to rotate. If a future amendment introduces a confidential client for a server-side backend, that secret lives in SSM PS and rotates via `terraform apply` on a bumped `generate_secret` toggle — document the procedure in an amendment to this section when that happens.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Browser redirect after login returns `400 redirect_mismatch` | The `redirect_uri` passed to `/login` does not exactly match any entry in the app client's `callback_urls` | Check Terraform state for `aws_cognito_user_pool_client.spa` — either update `config.yaml` `cognito.callback_urls` to include the URL used in the browser, or fix the browser URL. Scheme, host, path, and trailing-slash must match. |
| `admin-create-user` returns `AccessDeniedException` or `User is not authorized to perform: cognito-idp:AdminCreateUser` | The AWS profile in use does not have the `aegis-staging-admin` permission set assumed, or the IAM Identity Center permission set does not cover Cognito admin actions | Run `aws sts get-caller-identity`; confirm it returns the `aegis-staging-admin` role ARN. Re-run `aws sso login --sso-session aegis`. If the permission set genuinely lacks Cognito admin, widen via `management/bootstrap` (SSO assignments layer). |
| Token exchange on `/oauth2/token` returns `invalid_client` | App client ID mismatch between what the SPA (or curl) sends and what Cognito expects | Confirm `APP_CLIENT_ID` pulled from SSM matches the `client_id` query param used in Part 3. Also confirm the app client is configured for authorization code grant (`allowed_oauth_flows = ["code"]`). |
| ID token validates locally but gateway rejects with `token kid not found in JWKS` | Cognito rotated signing keys after the gateway fetched JWKS; gateway's cache has gone stale | Force a gateway restart (`kubectl rollout restart deployment gateway -n aegis`) — the middleware re-fetches JWKS on startup. For production, the middleware should implement lazy-refresh on unknown-kid, not rely on restart. Open an aegis-core issue if the middleware does not already handle this. |
| Hosted UI login succeeds but the user then gets "password reset required" on every subsequent login | `admin-set-user-password --permanent` was never run after `admin-create-user` | Re-run Part 2 step 3 with `--permanent`. Verify via `admin-get-user` that `UserStatus: CONFIRMED`. |
| Self-signup works when it shouldn't | `AllowAdminCreateUserOnly: true` is not set on the user pool | Check `aws_cognito_user_pool.this` `admin_create_user_config.allow_admin_create_user_only = true` in Terraform; re-apply. MVP posture per ADR-026 §Decision is self-signup disabled. |
| ExternalSecret `cognito-config` shows `SecretSyncedError: AccessDenied on ssm:GetParameter` | The External Secrets Operator IRSA role does not have permission on the new `/aegis/staging/cognito/*` path prefix | Check ESO's IAM policy in `staging/platform` — it should have a wildcard on `/aegis/staging/*` that already covers this. If it was written path-specifically for grafana-cloud/qdrant-cloud, widen it in a same-PR change. |

---

## Permanent teardown

> **CRITICAL**: deleting the Cognito User Pool destroys every registered user. Cognito does not export password hashes in any re-importable format. "Tear down and re-apply" is equivalent to "every user re-registers from scratch with password reset".

Tear down only when:

- Abandoning the lab permanently.
- Migrating to a different IdP (Auth0 / Okta / Keycloak).
- Recreating the pool because an immutable attribute declared at creation needs to change (see ADR-026 §Decision).

Teardown order:

1. **Export the user list** for migration prep — usernames, emails, custom attributes:

   ```bash
   aws cognito-idp list-users \
     --region eu-central-1 \
     --user-pool-id "$USER_POOL_ID" \
     --output json > users-backup-$(date +%Y%m%d).json
   ```

   Store the JSON somewhere off-repo. This is the only way to re-invite the same user list onto a successor IdP. Password hashes are **not** included — every user resets on the new IdP.

2. **Delete the ExternalSecret first** so the K8s Secret does not flap while SSM parameters are being destroyed:

   ```bash
   kubectl delete externalsecret cognito-config -n aegis
   ```

3. **`terraform destroy`** in `staging/auth/`:

   ```bash
   cd terraform/environments/staging/auth/
   terraform destroy
   ```

   This tears down the User Pool, app client, domain, IAM role, and the five SSM parameters in dependency order. The ExternalSecret was already deleted in step 2 — Terraform does not manage its lifecycle after namespace deletion.

4. **Clean up SSM parameters manually** if Terraform state was lost mid-teardown (five parameters exist: the three consumed by the ExternalSecret plus `user-pool-arn` and `hosted-ui-domain` for operator convenience):

   ```bash
   for key in user-pool-id user-pool-arn app-client-id issuer-url hosted-ui-domain; do
     aws ssm delete-parameter --name /aegis/staging/cognito/$key
   done
   ```

   Note: all five SSM parameters carry `lifecycle.prevent_destroy = true` in Terraform. To destroy them, you must first remove the lifecycle block (or `terraform state rm` them before `destroy`) — this is deliberate friction.

5. Remove the `cognito:` block from `config/landing-zone.yaml` so the layer plans to zero resources on any future baseline apply.

---

## Related

- [ADR-026](../decisions/026-cognito-auth-user-pool.md) — Cognito User Pool decision, including the deferred-implementation gate and the Q2 callback/logout URL Open Question.
- [ADR-022](../decisions/022-observability-backend-grafana-cloud.md) — precedent for the peer-layer + SSM PS + ExternalSecret pattern.
- [ADR-023](../decisions/023-observability-responsibility-model.md) — External Secrets responsibility split reused here.
- [Runbook 006](006-grafana-cloud-onboarding.md) — sibling SaaS onboarding (Grafana Cloud); same credential-plumbing shape.
- [Runbook 007](007-qdrant-cloud-onboarding.md) — sibling SaaS onboarding (Qdrant Cloud); most recent template for the shape this runbook follows.
