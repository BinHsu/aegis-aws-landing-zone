# -----------------------------------------------------------------------------
# Cognito User Pool Domain — Cognito-provided hosted UI domain (ADR-026)
# -----------------------------------------------------------------------------
# Fixed to the Cognito-provided `<prefix>.auth.<region>.amazoncognito.com`
# host per ADR-026 §Decision. Custom domain (`auth.staging.binhsu.org`)
# is deferred scope — requires an ACM cert in us-east-1 for Cognito's
# CloudFront front-end plus a Route53 record, neither of which pays off
# until demo polish matters.
#
# The domain prefix must be globally unique within the region. If a
# forker hits a collision, they bump the prefix in config.cognito.
# domain_prefix — this is why the default lives in config.tf with a
# try() fallback, not hardcoded here.
#
# Recreate semantics: changing the domain prefix forces recreate of the
# aws_cognito_user_pool_domain resource (the prefix is in the resource
# name). During recreate there is a ~30s window where the Hosted UI
# login URL returns 5xx; acceptable for a lab, not for production. If
# this becomes a concern, front the domain with a custom ACM cert so
# the prefix change becomes invisible to users.
# -----------------------------------------------------------------------------

resource "aws_cognito_user_pool_domain" "this" {
  count = local.auth_enabled ? 1 : 0

  domain       = local.domain_prefix
  user_pool_id = aws_cognito_user_pool.this[0].id
}
