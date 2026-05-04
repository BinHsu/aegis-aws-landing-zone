output "state_bucket_name" {
  description = "Terraform state S3 bucket name"
  value       = aws_s3_bucket.terraform_state.bucket
}

output "state_bucket_arn" {
  description = "Terraform state S3 bucket ARN"
  value       = aws_s3_bucket.terraform_state.arn
}

output "state_bucket_kms_key_arn" {
  description = "Customer-managed KMS key ARN for state bucket encryption (cross-account)"
  value       = aws_kms_key.terraform_state.arn
}

output "state_bucket_kms_key_alias" {
  description = "KMS key alias"
  value       = aws_kms_alias.terraform_state.name
}

output "account_id" {
  description = "Shared account ID"
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
