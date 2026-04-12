output "aft_management_account_id" {
  description = "Account ID where AFT is deployed"
  value       = module.aft.aft_management_account_id
}

output "vcs_provider" {
  description = "VCS provider configured for AFT"
  value       = module.aft.vcs_provider
}

output "account_request_repo_name" {
  description = "Repository name for AFT account requests"
  value       = module.aft.account_request_repo_name
}
