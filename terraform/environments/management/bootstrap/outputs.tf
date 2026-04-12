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

output "github_ci_role_arn" {
  description = "IAM role ARN for GitHub Actions CI/CD"
  value       = aws_iam_role.github_ci.arn
}

output "github_ci_role_name" {
  description = "IAM role name for GitHub Actions CI/CD"
  value       = aws_iam_role.github_ci.name
}
