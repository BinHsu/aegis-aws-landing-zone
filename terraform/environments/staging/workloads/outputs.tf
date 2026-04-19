output "namespace" {
  description = "Workload namespace name"
  value       = kubernetes_namespace_v1.aegis.metadata[0].name
}

output "engine_irsa_role_arn" {
  description = "IRSA role ARN for the aegis-engine ServiceAccount"
  value       = aws_iam_role.aegis_engine.arn
}

output "grafana_admin_password" {
  description = <<-EOT
    Grafana admin password — BREAK-GLASS USE ONLY.

    Regular access should be via SSO (see docs/improvements/009-grafana-sso-integration.md
    for the roadmap; until it ships, this is also daily-use auth).

    Regenerates on every fresh `terraform apply` of the workloads layer.
    Retrieval without shell-history leak:

      cd terraform/environments/staging/workloads
      AWS_PROFILE=aegis-staging-admin terraform output -raw grafana_admin_password | pbcopy

    See README.md "Grafana admin password — break-glass retrieval".
  EOT
  value       = random_password.grafana_admin.result
  sensitive   = true
}
