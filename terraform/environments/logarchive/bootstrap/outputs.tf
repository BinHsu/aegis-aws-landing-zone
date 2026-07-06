output "account_id" {
  description = "Logarchive account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "account_alias" {
  description = "IAM account alias"
  value       = aws_iam_account_alias.this.account_alias
}

output "github_oidc_provider_arn" {
  description = "GitHub OIDC identity provider ARN"
  value       = aws_iam_openid_connect_provider.github.arn
}

# -----------------------------------------------------------------------------
# Break-glass recovery role — ADR-015 OQ-1 graduation
# -----------------------------------------------------------------------------

output "aegis_emergency_break_glass_role_arn" {
  description = "ARN of the aegis-emergency-break-glass role for SSO PlatformAdmin assume during break-glass recovery"
  value       = aws_iam_role.aegis_emergency_break_glass.arn
}
