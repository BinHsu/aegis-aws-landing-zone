output "account_id" {
  description = "Staging account ID"
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

output "github_ci_role_arn" {
  description = "IAM role ARN for GitHub Actions CI/CD"
  value       = aws_iam_role.github_ci.arn
}

output "ecr_aegis_core_repository_url" {
  description = "ECR repository URL for the aegis-core application image"
  value       = aws_ecr_repository.aegis_core.repository_url
}

output "ecr_aegis_core_repository_arn" {
  description = "ECR repository ARN for the aegis-core application image"
  value       = aws_ecr_repository.aegis_core.arn
}

output "flow_logs_bucket_arn" {
  description = "S3 bucket ARN for VPC Flow Logs — consumed by staging/network"
  value       = aws_s3_bucket.flow_logs.arn
}
