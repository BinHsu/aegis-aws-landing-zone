# -----------------------------------------------------------------------------
# Outputs — per-cluster map, keyed by role-based slot name
# -----------------------------------------------------------------------------
# Downstream consumers (staging/workloads) read these maps indexed by slot
# name. Backward-compat flat primary-region outputs keep the workloads layer
# working until it is migrated to read from `clusters.primary.*`.
# -----------------------------------------------------------------------------

output "clusters" {
  description = "Per-cluster details, keyed by slot name (primary, slave_1, ...)"
  value = merge(
    {
      primary = {
        cluster_name                       = module.cluster_primary.cluster_name
        cluster_arn                        = module.cluster_primary.cluster_arn
        cluster_endpoint                   = module.cluster_primary.cluster_endpoint
        cluster_version                    = module.cluster_primary.cluster_version
        cluster_certificate_authority_data = module.cluster_primary.cluster_certificate_authority_data
        cluster_security_group_id          = module.cluster_primary.cluster_security_group_id
        oidc_provider_arn                  = module.cluster_primary.oidc_provider_arn
        oidc_provider_url                  = module.cluster_primary.oidc_provider_url
        fargate_pod_execution_role_arn     = module.cluster_primary.fargate_pod_execution_role_arn
        karpenter_node_role_arn            = module.cluster_primary.karpenter_node_role_arn
        karpenter_controller_role_arn      = module.cluster_primary.karpenter_controller_role_arn
        karpenter_interruption_queue_name  = module.cluster_primary.karpenter_interruption_queue_name
        lb_controller_role_arn             = module.cluster_primary.lb_controller_role_arn
        argocd_namespace                   = module.cluster_primary.argocd_namespace
        argocd_initial_admin_password_hint = module.cluster_primary.argocd_initial_admin_password_hint
        region_name                        = module.cluster_primary.region_name
        region_key                         = module.cluster_primary.region_key
      }
    },
    length(module.cluster_slave_1) > 0 ? {
      slave_1 = {
        cluster_name                       = module.cluster_slave_1[0].cluster_name
        cluster_arn                        = module.cluster_slave_1[0].cluster_arn
        cluster_endpoint                   = module.cluster_slave_1[0].cluster_endpoint
        cluster_version                    = module.cluster_slave_1[0].cluster_version
        cluster_certificate_authority_data = module.cluster_slave_1[0].cluster_certificate_authority_data
        cluster_security_group_id          = module.cluster_slave_1[0].cluster_security_group_id
        oidc_provider_arn                  = module.cluster_slave_1[0].oidc_provider_arn
        oidc_provider_url                  = module.cluster_slave_1[0].oidc_provider_url
        fargate_pod_execution_role_arn     = module.cluster_slave_1[0].fargate_pod_execution_role_arn
        karpenter_node_role_arn            = module.cluster_slave_1[0].karpenter_node_role_arn
        karpenter_controller_role_arn      = module.cluster_slave_1[0].karpenter_controller_role_arn
        karpenter_interruption_queue_name  = module.cluster_slave_1[0].karpenter_interruption_queue_name
        lb_controller_role_arn             = module.cluster_slave_1[0].lb_controller_role_arn
        argocd_namespace                   = module.cluster_slave_1[0].argocd_namespace
        argocd_initial_admin_password_hint = module.cluster_slave_1[0].argocd_initial_admin_password_hint
        region_name                        = module.cluster_slave_1[0].region_name
        region_key                         = module.cluster_slave_1[0].region_key
      }
    } : {}
  )
  sensitive = true # certificate_authority_data is sensitive inside each map
}

# -----------------------------------------------------------------------------
# Backward-compat flat primary-region outputs
# -----------------------------------------------------------------------------
# staging/workloads currently reads these flat. Keep pointing at the primary
# cluster until workloads migrates to consume `clusters.primary.*`.
# -----------------------------------------------------------------------------

output "cluster_name" {
  description = "Primary cluster name (backward-compat)"
  value       = module.cluster_primary.cluster_name
}

output "cluster_endpoint" {
  description = "Primary cluster API endpoint (backward-compat)"
  value       = module.cluster_primary.cluster_endpoint
}

output "cluster_version" {
  description = "Primary cluster Kubernetes version (backward-compat)"
  value       = module.cluster_primary.cluster_version
}

output "cluster_certificate_authority_data" {
  description = "Primary cluster CA (backward-compat)"
  value       = module.cluster_primary.cluster_certificate_authority_data
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "Primary cluster OIDC provider ARN (backward-compat)"
  value       = module.cluster_primary.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "Primary cluster OIDC URL (backward-compat)"
  value       = module.cluster_primary.oidc_provider_url
}

output "cluster_security_group_id" {
  description = "Primary cluster security group ID (backward-compat)"
  value       = module.cluster_primary.cluster_security_group_id
}

output "fargate_pod_execution_role_arn" {
  description = "Primary cluster Fargate pod execution role ARN (backward-compat)"
  value       = module.cluster_primary.fargate_pod_execution_role_arn
}

output "karpenter_node_role_arn" {
  description = "Primary cluster Karpenter node role ARN (backward-compat)"
  value       = module.cluster_primary.karpenter_node_role_arn
}

output "karpenter_controller_role_arn" {
  description = "Primary cluster Karpenter controller role ARN (backward-compat)"
  value       = module.cluster_primary.karpenter_controller_role_arn
}

output "karpenter_interruption_queue_name" {
  description = "Primary cluster Karpenter interruption queue name (backward-compat)"
  value       = module.cluster_primary.karpenter_interruption_queue_name
}

output "lb_controller_role_arn" {
  description = "Primary cluster LB Controller role ARN (backward-compat)"
  value       = module.cluster_primary.lb_controller_role_arn
}

output "argocd_namespace" {
  description = "Primary cluster ArgoCD namespace (backward-compat)"
  value       = module.cluster_primary.argocd_namespace
}

output "argocd_initial_admin_password_hint" {
  description = "Primary cluster ArgoCD admin password retrieval hint (backward-compat)"
  value       = module.cluster_primary.argocd_initial_admin_password_hint
}
