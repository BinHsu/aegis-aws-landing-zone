output "guardduty_detector_id" {
  description = "Delegated-admin GuardDuty detector ID (null when detective_enabled = false)"
  value       = var.detective_enabled ? aws_guardduty_detector.org[0].id : null
}

output "guardduty_auto_enable_organization_members" {
  description = "Org-wide GuardDuty member auto-enrollment mode (null when detective_enabled = false)"
  value       = var.detective_enabled ? aws_guardduty_organization_configuration.org[0].auto_enable_organization_members : null
}

output "securityhub_fsbp_subscription_arn" {
  description = "The single enabled Security Hub standard — FSBP (null when detective_enabled = false)"
  value       = var.detective_enabled ? aws_securityhub_standards_subscription.fsbp[0].id : null
}

output "detective_enabled" {
  description = "Lifecycle toggle state — false means the layer is code-complete but all billable detective resources are destroyed"
  value       = var.detective_enabled
}
