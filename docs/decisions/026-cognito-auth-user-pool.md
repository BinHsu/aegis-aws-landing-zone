# 026. Cognito User Pool — Cloud-mode auth for aegis

## Status

**Partially Accepted** (2026-04-23). Core commitment plus 5 of 6 shape decisions frozen per the aegis-core #76 reply later the same day. One Open Question remains — callback and logout URLs — genuinely blocked on aegis-core SPA auth scaffolding work that has not yet started. A strawman URL pair is the working default at Terraform commit time; Cognito's `callback_urls` and `logout_urls` accept updates to existing app clients without recreate, so Terraform implementation is not gated on resolving that question first.

The original Draft version of this document (2026-04-23 AM) recorded the commitment as decided and all six shape details as unpinned. This amendment (2026-04-23 PM, after aegis-core #76 was answered at 07:00 UTC) moves five of the six into § Decision and leaves the sixth in § Open Questions with the strawman default captured explicitly. A future amendment promotes this ADR from Partially Accepted to Accepted when aegis-core's SPA auth scaffold lands and the URL values are firm.

## Context

The landing zone has carried a standing commitment to provide Cognito-based auth for aegis-core's cloud-deployed app since the [README Phase 5 row](../../README.md#phases) was first drafted. This is ldz-side scope — not a new ask from aegis-core. What changed on 2026-04-23 is that this commitment moved onto the critical path: aegis-core's LAN smoke passed via [aegis-core #58](https://github.com/BinHsu/aegis-core/issues/58) and the image-readiness gate is now open, which means the next cold-apply can actually serve traffic — and serving traffic to a public URL without an auth layer is not a demo-worthy posture.

Cloud-mode splits the aegis-core surface along [ADR-019](019-frontend-serving-strategy.md): SPA at `aegis-app.staging.binhsu.org` (S3 + CloudFront) and gateway at `aegis-api.staging.binhsu.org` (ALB). Both endpoints need a common identity provider. The SPA needs an OAuth flow that lands users on Cognito's Hosted UI and redirects back with an authorization code; the gateway needs to validate the resulting ID token on every request.

The cost angle matters. Cognito User Pool free tier is **50,000 MAU permanent** — effectively \$0 at lab scale (1–5 MAU). This aligns with the free-tier discipline already established by [ADR-022](022-observability-backend-grafana-cloud.md) (Grafana Cloud) and [ADR-025](025-qdrant-backend-cloud-free-tier.md) (Qdrant Cloud): when a managed free tier covers portfolio scope, the cost argument dominates aesthetic preferences for self-hosting.

Cognito also fits the zero-static-credentials posture (CLAUDE.md § Security). aegis-core holds only OIDC tokens — short-lived, issuer-verifiable — not long-lived API keys. The platform provisions Cognito via Terraform and delivers `COGNITO_USER_POOL_ID`, `COGNITO_APP_CLIENT_ID`, and `COGNITO_ISSUER_URL` to the gateway Deployment via the same SSM Parameter Store → External Secrets Operator chain used for Grafana Cloud tokens and Qdrant credentials. Third repetition of the pattern — at this point it is the repo's default shape for managed-SaaS integration, not a new idea.

## Decision

Provision a **Cognito User Pool** (not Identity Pool — IAM-role-to-user mapping is not required for this app; the gateway does its own authorization on validated OIDC claims).

The user pool lives in a **new peer layer** `staging/auth/` with its own Terraform state. Auth is long-lived infrastructure (rotating user pools on every session would destroy registered users); it does not belong inside `staging/workloads/`, which is torn down routinely. This matches the peer-layer placement [ADR-022](022-observability-backend-grafana-cloud.md) chose for `staging/observability/` for the same reason: lifecycle mismatch with workloads.

The **Cognito-provided domain** (`aegis-<env>.auth.eu-central-1.amazoncognito.com`) is sufficient for MVP. A custom domain (`auth.staging.binhsu.org`) is future scope — it requires an ACM cert in `us-east-1` for Cognito's CloudFront-backed Hosted UI, which is a small but non-trivial slice of work that does not pay off until demo polish matters.

Credential delivery to aegis-core follows the established pattern. SSM PS paths:

```
/aegis/<env>/cognito/user-pool-id
/aegis/<env>/cognito/app-client-id
/aegis/<env>/cognito/issuer-url
```

A `cognito-config` Kubernetes Secret in the `aegis` namespace is reconciled by External Secrets Operator; the gateway Deployment mounts it as env vars. Unlike Grafana / Qdrant, none of these values are secret by themselves — `issuer-url` is a public JWKS endpoint, `user-pool-id` and `app-client-id` appear in every OAuth redirect the SPA performs. SSM PS is still the right delivery channel: consistency with the existing External Secrets wiring matters more than secret-vs-non-secret hair-splitting. SecureString is cheap; downgrading one family to String would complicate the IAM policy.

**MVP scope** is local users only. Self-signup is disabled; the operator invites users manually via `aws cognito-idp admin-create-user`. Google / GitHub IdP federation is a later slice when the demo narrative justifies the additional Terraform surface.

### Consumption contract decisions (frozen 2026-04-23 per aegis-core #76)

Five of the six shape details originally deferred are now pinned. The sixth (callback / logout URLs) remains in § Open Questions with a strawman default.

- **Token validation**: the gateway validates ID tokens locally against Cognito's JWKS endpoint (RS256). Removes a per-request network hop to `/userinfo`; the standard cloud-native path. Gateway middleware will need a JWKS cache tolerant of Cognito's key-rotation window.
- **Requested scopes**: `openid profile email` — no custom scopes for MVP. Role-based access is expressed through a custom attribute instead of through OAuth scopes (see next bullet); the gateway's authorization layer reads claims, not scopes.
- **User attributes**: one custom attribute declared at user pool creation — `custom:tenant_id`, **immutable**. Carries tenant identity for aegis-core's multi-tenancy model (aegis-core ADR-0022) into the ID token so the gateway does not need a per-request directory lookup. The attribute name is soft until aegis-core's multi-tenancy code stabilizes; if Cognito's `custom:` naming rules clash, aegis-core flags back on #76 and the user pool is recreated with the corrected name.
- **Session lifetime**: Cognito defaults — 1h access token, 30d refresh token. Acceptable for lab / demo scale. Revisit only if cold-apply smoke reveals UX pacing issues.
- **Logout behavior**: Cognito global logout — revokes the user's sessions across every client. Secure default; cleaner demo narrative (one Logout click → actually logged out everywhere). Local-only SPA logout was rejected because the app has no multi-device UX requirement that would justify the weaker posture.

The one remaining shape detail — callback / logout URLs — sits in § Open Questions with the strawman default captured.

## Alternatives Considered

### Auth0

Rejected primarily on cost. Free tier is 7,000 MAU — about an order of magnitude tighter than Cognito's 50,000 — and the paid tier starts around \$240/month for the Essentials plan with no meaningful lab-scale offering in between. Secondary rejection: Auth0 lives outside the AWS ecosystem, which means a separate billing relationship, a separate secret-delivery surface, and no native integration with future AWS services (e.g. Verified Permissions) if the authorization model ever needs to grow beyond OIDC claims.

### Okta

Rejected on cost posture. Okta has no free tier that covers production use — Okta Developer is explicitly trial / dev. Enterprise-grade capability but out of budget for a portfolio lab where the incremental skill signal over Cognito is close to zero at this scale.

### Keycloak self-hosted

Rejected on ops toil. A single-node Keycloak in-cluster is a single point of failure; making it HA requires a StatefulSet plus Infinispan cache plus an external PostgreSQL — operator-heavy enough that the lab would spend more time running Keycloak than integrating it. Same reasoning pattern as [ADR-025](025-qdrant-backend-cloud-free-tier.md)'s rejection of option A: a stateful-database-grade component managed by a single operator with no HA budget does not pay back the ops investment at 1–5 MAU. Also duplicates an existing portfolio axis (stateful-component operation via EKS + ArgoCD + External Secrets) rather than adding a new one.

### Roll our own JWT

Categorically wrong. "I re-implemented auth" is a portfolio anti-signal at staff / principal level; "I picked the right managed service and wired it correctly" is the expected answer. This is listed for completeness, not as a real alternative.

### Cognito User Pool (chosen)

50,000 MAU free tier; AWS-native IAM integration including future Verified Permissions if the app grows fine-grained authorization; Hosted UI reduces the SPA's auth-screen build scope to a redirect; JWKS-based token validation is an industry-standard pattern with first-class SDK support in the gateway's Go ecosystem. Lock-in is moderate and mitigated by sticking to standard OIDC (the user base is re-exportable to Auth0 / Okta / Keycloak with comparable OIDC surface; we do not rely on Cognito-proprietary features).

### Historical precedent — improvement 009 (obsoleted)

[`improvements/009-grafana-sso-integration.md`](../improvements/009-grafana-sso-integration.md) described the SAML-via-AWS-IAM-Identity-Center approach we would have used for Grafana in the self-hosted era. That doc is already obsoleted by [ADR-022](022-observability-backend-grafana-cloud.md); the reasoning pattern there — "IdC is the right IdP for operators logging into platform tools" — still holds. But aegis-core's users are not platform operators; they are application end-users, potentially including external invitees who are not in the lab's Identity Center directory. Identity Center is the wrong surface for end-user auth, which is why we reach for Cognito here rather than extending the IdC SAML story.

## Open Questions

### 1. Callback / redirect URLs (Q2 from the original 6)

**Status**: Open. aegis-core has no SPA auth scaffolding today — no `/auth/callback` route, no OAuth flow in the SPA, no post-logout redirect logic. The exact URLs are not yet designed and are blocked on the aegis-core-side SPA work starting.

**Working default for Terraform commit**: the Cognito app client's URL lists are seeded with strawman values that follow conventional SPA auth paths:

- `callback_urls = ["https://aegis-app.staging.binhsu.org/auth/callback"]`
- `logout_urls   = ["https://aegis-app.staging.binhsu.org/"]`

When aegis-core's SPA auth scaffolding finalizes (matching or diverging from the strawman), the operator runs `terraform apply` on `staging/auth/` with updated lists. Cognito accepts updates to `callback_urls` and `logout_urls` on existing app clients without forcing recreate, so this is a low-risk drift rather than a migration.

**Amendment trigger**: this ADR promotes from Partially Accepted to Accepted when aegis-core's SPA auth lands and the URL values are firm. If the production URLs differ from the strawman, the amendment captures the real values plus a note on whether the strawman was updated before or after first cold-apply.

The other five consumption-contract questions (token validation, scopes, custom attributes, session lifetime, logout behavior) were resolved by aegis-core's 2026-04-23 reply on [aegis-core #76](https://github.com/BinHsu/aegis-core/issues/76); see § Decision's "Consumption contract decisions" subsection.

## Consequences

These are projected; each will be reassessed when § Open Questions resolves.

**Cost**: \$0 at lab scale — well inside the 50,000 MAU free tier. No ongoing concern. If the lab's user count ever exceeds 50,000 the portfolio's framing has already changed fundamentally.

**Lock-in**: moderate. Migrating off Cognito means provisioning a new IdP and exporting the user pool. Mitigated by using only standard OIDC surface (no Cognito triggers, no Lambda hooks, no Cognito-proprietary custom challenge flows). The user base is portable to Auth0 / Okta / Keycloak with comparable OIDC capability.

**Operational surface**: minimal. Cognito is fully managed. The ops burden reduces to Terraform drift detection on the `staging/auth/` layer plus the usual token and user management via AWS CLI.

**Portfolio angle**: demonstrates Terraform-managed Cognito provisioning, cross-repo credential delivery contract (third instantiation of the SSM PS → External Secrets pattern), and zero-static-credentials discipline extended from platform tooling to the app auth layer. Strong staff / principal signal — "the pattern scales across concern types" is the argument.

**Future expansion**: federation (Google / GitHub) is a small additive slice when the demo narrative needs it — add an IdP resource and update the app client's supported IdPs. Custom domain is a small slice when polish matters — add an ACM cert in `us-east-1` and a `aws_cognito_user_pool_domain` resource. Multi-tenant attribute schema (aegis-core ADR-0022 alignment) is larger — may trigger an ADR-026 amendment or a separate ADR depending on how aegis-core's tenancy model actually lands.

**Migration path if we ever switch**: standard OIDC discipline means the gateway's middleware does not change. What changes is the `COGNITO_ISSUER_URL` becomes an `OIDC_ISSUER_URL` and the Terraform provider swaps. Users must be re-invited into the new IdP; there is no automated export for Cognito password hashes.

## Related

- [ADR-019](019-frontend-serving-strategy.md) — split-subdomain topology (`aegis-app` SPA + `aegis-api` gateway) that Cognito callback and logout URLs target.
- [ADR-022](022-observability-backend-grafana-cloud.md) — precedent for managed-SaaS + SSM PS + External Secrets delivery.
- [ADR-023](023-observability-responsibility-model.md) — External Secrets pattern, reused for Cognito credentials.
- [ADR-025](025-qdrant-backend-cloud-free-tier.md) — most recent ADR applying the same free-tier discipline and deferred-implementation gate; this ADR follows the same shape.
- [`improvements/009-grafana-sso-integration.md`](../improvements/009-grafana-sso-integration.md) (obsoleted) — prior IdC SAML story, kept for historical context on why Identity Center is the wrong IdP for end-user auth.
- [aegis-core #76](https://github.com/BinHsu/aegis-core/issues/76) — the live consumption-contract coordination thread carrying the 6 Open Questions.
