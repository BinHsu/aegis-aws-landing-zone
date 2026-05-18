# -----------------------------------------------------------------------------
# Outputs — flat, single-region (ADR-032)
# -----------------------------------------------------------------------------
# This layer's state holds exactly one cluster. staging/workloads reads these
# outputs from the region-scoped state key staging/<region>/platform/...
# -----------------------------------------------------------------------------

output "region" {
  description = "AWS region this cluster runs in"
  value       = local.region
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.cluster.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.cluster.cluster_endpoint
}

output "cluster_version" {
  description = "EKS cluster Kubernetes version"
  value       = module.cluster.cluster_version
}

output "cluster_certificate_authority_data" {
  description = "EKS cluster CA data"
  value       = module.cluster.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "EKS cluster security group ID"
  value       = module.cluster.cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "EKS cluster OIDC provider ARN"
  value       = module.cluster.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "EKS cluster OIDC provider URL"
  value       = module.cluster.oidc_provider_url
}

output "fargate_pod_execution_role_arn" {
  description = "Fargate pod execution role ARN"
  value       = module.cluster.fargate_pod_execution_role_arn
}

output "karpenter_node_role_arn" {
  description = "Karpenter node role ARN"
  value       = module.cluster.karpenter_node_role_arn
}

output "karpenter_controller_role_arn" {
  description = "Karpenter controller role ARN"
  value       = module.cluster.karpenter_controller_role_arn
}

output "karpenter_interruption_queue_name" {
  description = "Karpenter interruption queue name"
  value       = module.cluster.karpenter_interruption_queue_name
}

output "lb_controller_role_arn" {
  description = "AWS Load Balancer Controller role ARN"
  value       = module.cluster.lb_controller_role_arn
}

output "argocd_namespace" {
  description = "ArgoCD namespace"
  value       = module.cluster.argocd_namespace
}

output "argocd_initial_admin_password_hint" {
  description = "ArgoCD admin password retrieval hint"
  value       = module.cluster.argocd_initial_admin_password_hint
}
