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

# -----------------------------------------------------------------------------
# aegis-core CI outputs — consumed by aegis-core's GitHub Actions workflows
# -----------------------------------------------------------------------------

output "aegis_core_ecr_role_arn" {
  description = "IAM role ARN for aegis-core CI → ECR push (least-privilege, main branch only)"
  value       = aws_iam_role.aegis_core_ecr.arn
}

output "aegis_core_cache_role_arn" {
  description = "IAM role ARN for aegis-core CI → S3 Bazel cache (least-privilege, main branch only)"
  value       = aws_iam_role.aegis_core_cache.arn
}

output "bazel_cache_bucket_name" {
  description = "S3 bucket name for Bazel remote cache"
  value       = aws_s3_bucket.bazel_cache.bucket
}

output "bazel_cache_bucket_arn" {
  description = "S3 bucket ARN for Bazel remote cache"
  value       = aws_s3_bucket.bazel_cache.arn
}

# -----------------------------------------------------------------------------
# SSM PS SecureString encryption key — consumed by staging/platform
# (ESO IRSA policy) and staging/observability (aws_ssm_parameter.key_id).
# -----------------------------------------------------------------------------

output "secrets_kms_key_arn" {
  description = "KMS key ARN for /aegis/staging/grafana-cloud/* SSM PS SecureString encryption (ADR-022)"
  value       = aws_kms_key.secrets.arn
}

output "secrets_kms_key_alias" {
  description = "KMS key alias (alias/aegis-staging-secrets) — matches Runbook 006 Part 2 step 5"
  value       = aws_kms_alias.secrets.name
}
