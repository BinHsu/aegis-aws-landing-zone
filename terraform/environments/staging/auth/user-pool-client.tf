# -----------------------------------------------------------------------------
# Cognito User Pool Client — public SPA client for aegis-core (ADR-026)
# -----------------------------------------------------------------------------
# Single app client for the aegis-core SPA. Public client (no secret)
# because it runs in a browser — the authorization-code + PKCE flow
# replaces the client_secret for security.
#
# Token lifetimes: Cognito defaults (1h access, 30d refresh). Accepted
# by aegis-core #76 Q5. Tighten only if cold-apply smoke reveals UX
# pacing issues — shorter access tokens = more refresh calls = more
# gateway load for no demo-level benefit.
#
# OAuth flows + scopes (aegis-core #76 Q3): `openid profile email`
# scopes with `authorization-code` flow. No custom scopes — role-based
# authorization lives in `custom:tenant_id` claim, not in OAuth scopes.
#
# ALLOW_ADMIN_USER_PASSWORD_AUTH is specifically enabled for aegis-core's
# nightly integration test (aegis-core #76 Q B) — their test harness
# uses `AdminInitiateAuth` with the `ADMIN_USER_PASSWORD_AUTH` flow to
# mint a token without browser interaction. Production login flows all
# go through USER_SRP_AUTH via the Hosted UI.
#
# Callback + logout URLs: Cognito accepts in-place updates to these
# lists without recreate (aws_cognito_user_pool_client is update-safe on
# these fields). aegis-core #76 Q2 confirmed the strawman values as
# final; they now live in `config/landing-zone.yaml` (or fall back to
# the strawman defaults in config.tf).
# -----------------------------------------------------------------------------

resource "aws_cognito_user_pool_client" "spa" {
  count = local.auth_enabled ? 1 : 0

  name         = "aegis-cloud-spa"
  user_pool_id = aws_cognito_user_pool.this[0].id

  # Public client — the SPA cannot safely hold a secret. PKCE is the
  # replacement for client_secret in browser-based OAuth flows.
  generate_secret = false

  # Token lifetimes — Cognito defaults (aegis-core #76 Q5 accepted).
  refresh_token_validity = 30
  access_token_validity  = 1
  id_token_validity      = 1
  token_validity_units {
    refresh_token = "days"
    access_token  = "hours"
    id_token      = "hours"
  }

  # OAuth surface — authorization-code flow + PKCE; standard SPA pattern.
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "profile", "email"]

  callback_urls = local.callback_urls
  logout_urls   = local.logout_urls

  # No IdP federation today (ADR-026 §Decision). Future amendment adds
  # Google / GitHub here plus `aws_cognito_identity_provider` resources.
  supported_identity_providers = ["COGNITO"]

  # Explicit auth flows — SRP for Hosted UI login, refresh for session
  # persistence, admin-user-password for aegis-core nightly CI
  # (aegis-core #76 Q B). No ALLOW_USER_PASSWORD_AUTH — that flow sends
  # the password directly to Cognito over TLS without SRP, which is
  # generally discouraged.
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_ADMIN_USER_PASSWORD_AUTH",
  ]

  # Best-practice security: on failed login, return the same error
  # whether or not the username exists. Prevents username enumeration.
  prevent_user_existence_errors = "ENABLED"

  # Explicitly enable token revocation so the global-logout endpoint
  # actually revokes refresh tokens server-side (not just client-side).
  # aegis-core #76 Q6: Cognito global logout accepted.
  enable_token_revocation = true

  lifecycle {
    prevent_destroy = true
  }
}
