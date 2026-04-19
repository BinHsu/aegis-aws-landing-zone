variable "region_key" {
  description = "Role-based key for this region (e.g. \"primary\", \"slave_1\"). Used in resource name tags so multiple VPCs within a single state file are human-distinguishable."
  type        = string
}

variable "region_name" {
  description = "AWS region name (e.g. \"eu-central-1\"). Purely informational within the module — the actual region is determined by the passed-in provider."
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
  description = "Regional IPAM pool ID to allocate this VPC's CIDR from. Must be a pool whose locale matches region_name."
  type        = string
}

variable "flow_logs_bucket_arn" {
  description = "ARN of the S3 bucket that receives VPC flow logs. If null, the flow log resource is skipped (useful when bootstrap has not yet been applied)."
  type        = string
  default     = null
}

variable "env_name" {
  description = "Environment label for resource Name tags (e.g. \"staging\"). Combined with region_key to produce names like \"staging-primary-vpc\"."
  type        = string
}
