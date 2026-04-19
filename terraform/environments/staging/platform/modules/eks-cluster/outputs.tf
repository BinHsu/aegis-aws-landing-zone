output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = aws_eks_cluster.main.arn
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
  description = "Base64-encoded cluster CA certificate"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "Cluster security group AWS creates for control plane <-> node"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "IAM OIDC identity provider ARN for IRSA trust policies"
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "oidc_provider_url" {
  description = "OIDC issuer URL (no scheme) for IRSA sub claim conditions"
  value       = local.oidc_host
}

output "fargate_pod_execution_role_arn" {
  description = "Fargate pod execution role ARN"
  value       = aws_iam_role.fargate_pod_execution.arn
}

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

output "lb_controller_role_arn" {
  description = "AWS Load Balancer Controller IAM role ARN (IRSA-bound)"
  value       = aws_iam_role.lb_controller.arn
}

output "argocd_namespace" {
  description = "Namespace where ArgoCD is installed"
  value       = helm_release.argocd.namespace
}

output "argocd_initial_admin_password_hint" {
  description = "Command to retrieve the initial ArgoCD admin password for THIS cluster"
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.main.name} --region ${var.region_name} && kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "region_name" {
  description = "AWS region where this cluster runs"
  value       = var.region_name
}

output "region_key" {
  description = "Role-based slot key for this cluster (primary, slave_1, ...)"
  value       = var.region_key
}
