output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  description = "EKS Kubernetes version"
  value       = aws_eks_cluster.main.version
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded cluster CA certificate — consumed by the kubernetes/helm providers in follow-up PRs"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "IAM OIDC identity provider ARN for IRSA trust policies"
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "oidc_provider_url" {
  description = "OIDC issuer URL (no scheme) for IRSA sub claim conditions"
  value       = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

output "cluster_security_group_id" {
  description = "The cluster security group AWS creates for control plane ↔ node communication"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "fargate_pod_execution_role_arn" {
  description = "Fargate pod execution role ARN — reused by future Fargate profiles if added"
  value       = aws_iam_role.fargate_pod_execution.arn
}

# -----------------------------------------------------------------------------
# Karpenter outputs — consumed by downstream PRs (LB Controller discovers
# node role tags; ArgoCD may reference the NodePool name for app placement).
# -----------------------------------------------------------------------------

output "karpenter_node_role_arn" {
  description = "Karpenter-managed EC2 node IAM role ARN"
  value       = aws_iam_role.karpenter_node.arn
}

output "karpenter_controller_role_arn" {
  description = "Karpenter controller IAM role ARN (IRSA-bound to karpenter/karpenter SA)"
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_interruption_queue_name" {
  description = "SQS queue name Karpenter polls for Spot / scheduled-change events"
  value       = aws_sqs_queue.karpenter_interruption.name
}

# -----------------------------------------------------------------------------
# Ingress + GitOps outputs (Phase 3c PR 3)
# -----------------------------------------------------------------------------

output "lb_controller_role_arn" {
  description = "AWS Load Balancer Controller IAM role ARN (IRSA-bound)"
  value       = aws_iam_role.lb_controller.arn
}

output "argocd_namespace" {
  description = "Namespace where ArgoCD is installed"
  value       = helm_release.argocd.namespace
}

output "argocd_initial_admin_password_hint" {
  description = "Command to retrieve the initial ArgoCD admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
