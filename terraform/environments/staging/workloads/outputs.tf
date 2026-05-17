# -----------------------------------------------------------------------------
# Outputs — flat, single-region (ADR-032)
# -----------------------------------------------------------------------------
# Workloads is a leaf layer: no downstream Terraform consumer reads these
# outputs (they are operator-facing only).
# -----------------------------------------------------------------------------

output "region" {
  description = "AWS region this workloads state covers"
  value       = local.region
}

output "namespace" {
  description = "Application Kubernetes namespace"
  value       = module.workloads.namespace
}

output "engine_irsa_role_arn" {
  description = "Engine IRSA role ARN"
  value       = module.workloads.engine_irsa_role_arn
}

output "guardduty_detector_id" {
  description = "GuardDuty detector ID for this region"
  value       = module.workloads.guardduty_detector_id
}
