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
