output "account_id" {
  description = "Management account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "organization_id" {
  description = "AWS Organizations ID"
  value       = data.aws_organizations_organization.current.id
}

output "organization_root_id" {
  description = "AWS Organizations root ID"
  value       = data.aws_organizations_organization.current.roots[0].id
}

output "account_alias" {
  description = "IAM account alias"
  value       = aws_iam_account_alias.this.account_alias
}

output "github_oidc_provider_arn" {
  description = "GitHub OIDC identity provider ARN"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "aegis_emergency_break_glass_role_arn" {
  description = "ARN of the aegis-emergency-break-glass role for SSO PlatformAdmin assume during break-glass recovery"
  value       = aws_iam_role.aegis_emergency_break_glass.arn
}
