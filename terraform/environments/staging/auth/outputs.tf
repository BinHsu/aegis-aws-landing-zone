# -----------------------------------------------------------------------------
# Outputs — aegis-core consumption contract (aegis-core #76 Q A)
# -----------------------------------------------------------------------------
# Six outputs documented as the stable surface this layer exposes:
#
#   - cognito_user_pool_id                  — for gateway + CI
#   - cognito_user_pool_arn                 — for IAM policies
#   - cognito_app_client_id                 — for SPA + gateway aud check
#   - cognito_issuer_url                    — for JWKS / OIDC discovery
#   - cognito_hosted_ui_domain              — for OAuth redirect URLs
#   - aegis_core_cognito_integration_role_arn — aegis-core nightly CI assumes
#
# Values are wrapped in try() so `terraform output` works even when the
# layer has auth_enabled = false (it prints null for everything). No
# sensitive = true — none of these are secrets; they appear in every
# OAuth redirect the SPA performs anyway.
#
# aegis-core reads values via SSM PS on each nightly run (per #76 Q A-2),
# not via remote_state. These outputs exist for:
#   - operator inspection (`terraform output`)
#   - a future same-repo layer that wants remote_state access
#   - debuggability when the SSM PS chain fails
# -----------------------------------------------------------------------------

output "auth_enabled" {
  description = "Whether the auth layer provisioned any resources (true when config.cognito is present, false otherwise)."
  value       = local.auth_enabled
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID (e.g. eu-central-1_abc12). Null when auth_enabled=false. Also published at SSM PS /aegis/staging/cognito/user-pool-id."
  value       = try(aws_cognito_user_pool.this[0].id, null)
}

output "cognito_user_pool_arn" {
  description = "Cognito User Pool ARN. Null when auth_enabled=false. Also published at SSM PS /aegis/staging/cognito/user-pool-arn."
  value       = try(aws_cognito_user_pool.this[0].arn, null)
}

output "cognito_app_client_id" {
  description = "Cognito App Client ID for the SPA. Null when auth_enabled=false. Also published at SSM PS /aegis/staging/cognito/app-client-id."
  value       = try(aws_cognito_user_pool_client.spa[0].id, null)
}

output "cognito_issuer_url" {
  description = "OIDC issuer URL; the iss claim value of tokens issued by this pool. Null when auth_enabled=false. Also published at SSM PS /aegis/staging/cognito/issuer-url."
  value       = local.auth_enabled ? "https://cognito-idp.${local.primary_region}.amazonaws.com/${aws_cognito_user_pool.this[0].id}" : null
}

output "cognito_hosted_ui_domain" {
  description = "Fully-qualified Hosted UI domain (e.g. aegis-staging.auth.eu-central-1.amazoncognito.com). Null when auth_enabled=false. Also published at SSM PS /aegis/staging/cognito/hosted-ui-domain."
  value       = local.auth_enabled ? "${aws_cognito_user_pool_domain.this[0].domain}.auth.${local.primary_region}.amazoncognito.com" : null
}

output "aegis_core_cognito_integration_role_arn" {
  description = "ARN of the IAM role aegis-core's nightly integration workflow assumes via GitHub OIDC. Scoped to Cognito admin actions on the staging user pool + SSM PS read on /aegis/staging/cognito/*. Null when auth_enabled=false."
  value       = try(aws_iam_role.aegis_core_cognito_integration[0].arn, null)
}

output "ssm_paths" {
  description = "SSM PS paths for the five Cognito identifiers. Values are NOT output (secure by location). Retrieve with: aws ssm get-parameter --name <path> --with-decryption."
  value = local.auth_enabled ? {
    user_pool_id     = "${local.ssm_path_prefix}/user-pool-id"
    user_pool_arn    = "${local.ssm_path_prefix}/user-pool-arn"
    app_client_id    = "${local.ssm_path_prefix}/app-client-id"
    issuer_url       = "${local.ssm_path_prefix}/issuer-url"
    hosted_ui_domain = "${local.ssm_path_prefix}/hosted-ui-domain"
  } : null
}
