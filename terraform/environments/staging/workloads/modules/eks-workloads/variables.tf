variable "region_key" {
  description = "Role-based slot name for this cluster (primary, slave_1, ...). Used in tags so multiple clusters in the same state file are human-distinguishable."
  type        = string
}

variable "region_name" {
  description = "AWS region name for this cluster (e.g. eu-central-1). Sourced from config via the parent layer; never hardcoded."
  type        = string
}

variable "cluster_name" {
  description = "Full EKS cluster name (e.g. aegis-staging-primary). Drives IAM role names for IRSA and tag values."
  type        = string
}

variable "oidc_provider_arn" {
  description = "IAM OIDC identity provider ARN for this cluster. Used in IRSA trust policies."
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC issuer URL (no scheme) for this cluster. Used in IRSA `sub` and `aud` claim conditions."
  type        = string
}

variable "tags" {
  description = "Tags merged onto AWS resources this module creates. Slot-identity tag (e.g. RegionRole=primary) is added by the module."
  type        = map(string)
  default     = {}
}
