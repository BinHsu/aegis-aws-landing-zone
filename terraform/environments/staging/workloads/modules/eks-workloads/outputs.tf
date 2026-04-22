output "namespace" {
  description = "Workload namespace name in this cluster"
  value       = kubernetes_namespace_v1.aegis.metadata[0].name
}

output "engine_irsa_role_arn" {
  description = "IRSA role ARN for the aegis-engine ServiceAccount in this cluster"
  value       = aws_iam_role.aegis_engine.arn
}

output "guardduty_detector_id" {
  description = "GuardDuty detector ID for this cluster's region"
  value       = aws_guardduty_detector.staging.id
}
