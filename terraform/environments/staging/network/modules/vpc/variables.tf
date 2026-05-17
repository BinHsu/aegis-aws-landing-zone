variable "region" {
  description = "AWS region name (e.g. \"eu-central-1\"). Used in resource Name tags. The actual region is set by the layer's default provider — this layer applies one region per state file (ADR-032)."
  type        = string
}

variable "zones" {
  description = "Availability Zones to place subnets in. Subnet count equals length of this list."
  type        = list(string)
}

variable "netmask_length" {
  description = "VPC netmask length; IPAM allocates a block of this size."
  type        = number
}

variable "ipam_pool_id" {
  description = "Regional IPAM pool ID to allocate this VPC's CIDR from. Must be a pool whose locale matches the region."
  type        = string
}

variable "flow_logs_bucket_arn" {
  description = "ARN of the S3 bucket that receives VPC flow logs. If null, the flow log resource is skipped (useful when bootstrap has not yet been applied)."
  type        = string
  default     = null
}

variable "env_name" {
  description = "Environment label for resource Name tags (e.g. \"staging\"). Combined with region to produce names like \"staging-eu-central-1-vpc\"."
  type        = string
}
