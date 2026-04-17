output "namespace" {
  description = "Workload namespace name"
  value       = kubernetes_namespace_v1.aegis.metadata[0].name
}

output "engine_irsa_role_arn" {
  description = "IRSA role ARN for the aegis-engine ServiceAccount"
  value       = aws_iam_role.aegis_engine.arn
}
