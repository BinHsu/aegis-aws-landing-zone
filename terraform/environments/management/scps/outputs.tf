output "scp_deny_root_user_id" {
  description = "SCP policy ID: deny root user actions"
  value       = aws_organizations_policy.deny_root_user.id
}

output "scp_deny_iam_users_id" {
  description = "SCP policy ID: deny IAM user creation"
  value       = aws_organizations_policy.deny_iam_users.id
}

output "scp_deny_leave_org_id" {
  description = "SCP policy ID: deny leaving organization"
  value       = aws_organizations_policy.deny_leave_org.id
}
