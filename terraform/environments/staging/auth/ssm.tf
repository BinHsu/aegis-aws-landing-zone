# -----------------------------------------------------------------------------
# SSM PS writeback — Cognito identifiers for aegis-core consumption (ADR-026)
# -----------------------------------------------------------------------------
# Five SecureString parameters encrypted with the shared secrets CMK
# (alias/aegis-staging-secrets). External Secrets Operator reads three
# of them (user-pool-id, app-client-id, issuer-url) via the `aegis-ssm`
# ClusterSecretStore and reconciles them into the `cognito-config` K8s
# Secret in the `aegis` namespace.
#
# Why SecureString even though these are not strictly secret (issuer-url
# is a public JWKS URL, user-pool-id and app-client-id leak in every
# OAuth redirect): the ESO ClusterSecretStore IAM policy is already
# scoped to SecureString parameters under /aegis/staging/*. Splitting
# one family to plain `String` would complicate the IAM policy for
# zero benefit. Consistency with grafana_cloud + qdrant_cloud wins.
#
# SSM Parameter Store does NOT support a KMS key alias via the
# `alias/...` shorthand; it requires the target key ARN. We resolve it
# via the `data "aws_kms_alias" "secrets"` lookup in config.tf.
#
# prevent_destroy = true: accidental `terraform destroy` of these
# parameters would break the `cognito-config` ExternalSecret reconcile
# loop until a re-apply. The User Pool itself has prevent_destroy for
# user-data reasons; these SSM params mirror it so Terraform refuses to
# lose pool → credential linkage without explicit operator action.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# 1. user-pool-id — consumed by gateway's OIDC middleware + aegis-core CI
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "user_pool_id" {
  count = local.auth_enabled ? 1 : 0

  name        = "${local.ssm_path_prefix}/user-pool-id"
  description = "Cognito User Pool ID (e.g. eu-central-1_abc12). Provisioned by terraform/environments/staging/auth/; consumed by ExternalSecret → K8s Secret cognito-config (key COGNITO_USER_POOL_ID) in ns aegis, and by aegis-core's nightly integration workflow."
  type        = "SecureString"
  key_id      = data.aws_kms_alias.secrets[0].target_key_arn
  tier        = "Standard"
  value       = aws_cognito_user_pool.this[0].id

  tags = merge(local.tags, {
    Name = "cognito-user-pool-id"
  })

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# 2. user-pool-arn — useful for IAM policies if the role grows
# -----------------------------------------------------------------------------
# Not currently consumed by the K8s-side ExternalSecret (gateway does
# not need the ARN, only the pool ID for issuer-URL construction). Kept
# as a Terraform output + SSM PS writeback for future consumers (e.g. a
# Verified Permissions policy or a Lambda hook).
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "user_pool_arn" {
  count = local.auth_enabled ? 1 : 0

  name        = "${local.ssm_path_prefix}/user-pool-arn"
  description = "Cognito User Pool ARN. Provisioned by terraform/environments/staging/auth/; not currently wired through ExternalSecret but available for future IAM policy targets or Lambda hooks."
  type        = "SecureString"
  key_id      = data.aws_kms_alias.secrets[0].target_key_arn
  tier        = "Standard"
  value       = aws_cognito_user_pool.this[0].arn

  tags = merge(local.tags, {
    Name = "cognito-user-pool-arn"
  })

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# 3. app-client-id — consumed by SPA + gateway (audience claim check)
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "app_client_id" {
  count = local.auth_enabled ? 1 : 0

  name        = "${local.ssm_path_prefix}/app-client-id"
  description = "Cognito App Client ID for the aegis SPA. Provisioned by terraform/environments/staging/auth/; consumed by ExternalSecret → K8s Secret cognito-config (key COGNITO_APP_CLIENT_ID) in ns aegis, and by the SPA's OAuth redirect URLs."
  type        = "SecureString"
  key_id      = data.aws_kms_alias.secrets[0].target_key_arn
  tier        = "Standard"
  value       = aws_cognito_user_pool_client.spa[0].id

  tags = merge(local.tags, {
    Name = "cognito-app-client-id"
  })

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# 4. issuer-url — consumed by gateway for OIDC discovery + JWKS
# -----------------------------------------------------------------------------
# Format: https://cognito-idp.<region>.amazonaws.com/<user-pool-id>
# This is the `iss` claim value tokens will carry AND the base URL for
# Cognito's OIDC discovery document (/.well-known/openid-configuration)
# plus JWKS endpoint (/.well-known/jwks.json).
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "issuer_url" {
  count = local.auth_enabled ? 1 : 0

  name        = "${local.ssm_path_prefix}/issuer-url"
  description = "Cognito OIDC issuer URL. Provisioned by terraform/environments/staging/auth/; consumed by ExternalSecret → K8s Secret cognito-config (key COGNITO_ISSUER_URL) in ns aegis. Format: https://cognito-idp.<region>.amazonaws.com/<user-pool-id>. JWKS lives at <issuer>/.well-known/jwks.json."
  type        = "SecureString"
  key_id      = data.aws_kms_alias.secrets[0].target_key_arn
  tier        = "Standard"
  value       = "https://cognito-idp.${local.primary_region}.amazonaws.com/${aws_cognito_user_pool.this[0].id}"

  tags = merge(local.tags, {
    Name = "cognito-issuer-url"
  })

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# 5. hosted-ui-domain — full hosted-UI URL (convenience output)
# -----------------------------------------------------------------------------
# Full URL: <prefix>.auth.<region>.amazoncognito.com. aegis-core's
# nightly integration workflow and any browser-redirect tooling reads
# this instead of reconstructing from prefix + region. Avoids drift if
# we ever cut over to a custom domain in a future amendment.
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "hosted_ui_domain" {
  count = local.auth_enabled ? 1 : 0

  name        = "${local.ssm_path_prefix}/hosted-ui-domain"
  description = "Cognito Hosted UI fully-qualified domain. Provisioned by terraform/environments/staging/auth/; consumed by aegis-core's nightly integration workflow for OAuth URL construction. Format: <prefix>.auth.<region>.amazoncognito.com."
  type        = "SecureString"
  key_id      = data.aws_kms_alias.secrets[0].target_key_arn
  tier        = "Standard"
  value       = "${aws_cognito_user_pool_domain.this[0].domain}.auth.${local.primary_region}.amazoncognito.com"

  tags = merge(local.tags, {
    Name = "cognito-hosted-ui-domain"
  })

  lifecycle {
    prevent_destroy = true
  }
}
