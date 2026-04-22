variable "region_key" {
  description = "Role-based slot name for this cluster (primary, slave_1, ...). Used in resource names and tags so multiple clusters in the same state file are human-distinguishable."
  type        = string
}

variable "region_name" {
  description = "AWS region name for this cluster (e.g. eu-central-1). Used in Karpenter's IAM policy ARN constraints, Access Entries cross-references, and the exec-based EKS token commands for the kubernetes/helm/kubectl providers. Sourced from config, never hardcoded."
  type        = string
}

variable "cluster_name" {
  description = "Full EKS cluster name (e.g. aegis-staging-primary). Drives IAM role names, KMS alias, CloudWatch log group, and the EKS cluster resource itself."
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for this cluster (e.g. 1.32). See config.eks.<env>.version in landing-zone.yaml."
  type        = string
}

variable "public_access_cidrs" {
  description = "CIDR list allowed to reach the EKS public API endpoint. See docs/runbooks/002-eks-access.md for the operational contract."
  type        = list(string)
}

variable "account_id" {
  description = "AWS account ID hosting this cluster. Used in IAM role trust policies and KMS key policies."
  type        = string
}

variable "organization_name" {
  description = "Organization prefix from config.organization.name (e.g. aegis). Used in group names (Kubernetes RBAC), ArgoCD repo references. Project-identity strings — hardcoding the literal \"aegis\" is acceptable per CLAUDE.md, but sourcing from config keeps forkers consistent."
  type        = string
}

variable "tags" {
  description = "Tags merged onto all resources this module creates (via default_tags on the provider + explicit tag blocks)."
  type        = map(string)
  default     = {}
}

variable "vpc_id" {
  description = "VPC ID for this cluster's region, from the staging/network layer. Used by the AWS LB Controller helm values (vpcId). Explicit vs auto-discovery to avoid IMDS reliance in CI."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs in this cluster's region, from the staging/network layer. Used in aws_eks_cluster.vpc_config."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs in this cluster's region, from the staging/network layer. Used in aws_eks_cluster.vpc_config and Fargate profiles."
  type        = list(string)
}

variable "availability_zones" {
  description = "AZ list for this cluster's region. Used as Karpenter NodePool topology constraint."
  type        = list(string)
}

variable "ci_role_arn" {
  description = "ARN of the GitHub Actions CI role that gets cluster-admin via Access Entry. Same role across all clusters in the account (account-global IAM)."
  type        = string
}

variable "github_org" {
  description = "GitHub organization that owns the app repo (for ArgoCD root Application repoURL)."
  type        = string
}

variable "github_app_repo" {
  description = "GitHub repository name of the app/manifest source (e.g. aegis-core)."
  type        = string
}

variable "argocd_apps_path" {
  description = "Path within the app repo where ArgoCD's root Application reads child apps. Defaulted to apps/staging; override per-cluster when slave regions use a different app set (e.g. pilot-light subset)."
  type        = string
  default     = "apps/staging"
}

# -----------------------------------------------------------------------------
# Observability stack inputs (ADR-022)
# -----------------------------------------------------------------------------

variable "observability_enabled" {
  description = "Gate for the platform observability stack (ESO + prometheus-operator-crds + kube-state-metrics + Alloy). Driven by config.grafana_cloud presence at the parent layer. When false, none of these four Helm releases are created."
  type        = bool
  default     = false
}

variable "primary_region" {
  description = "Primary AWS region (from config.regions[].role=primary). Per ADR-022 §Multi-region, the Grafana Cloud SSM PS parameters live only in the primary region; slave clusters' ESO reads cross-region. Used in the ESO IRSA policy's resource ARNs + kms:ViaService condition."
  type        = string
  default     = ""
}

variable "secrets_kms_key_arn" {
  description = "ARN of alias/aegis-staging-secrets (created in staging/bootstrap/kms-secrets.tf). Used in the ESO IRSA policy's kms:Decrypt statement. Empty string when observability_enabled=false."
  type        = string
  default     = ""
}

variable "grafana_cloud" {
  description = "Grafana Cloud stack endpoints (ADR-022). Consumed by Alloy remote_write config. Null when observability_enabled=false."
  type = object({
    org_slug      = string
    mimir_url     = string
    mimir_user_id = string
  })
  default = null
}
