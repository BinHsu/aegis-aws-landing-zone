# -----------------------------------------------------------------------------
# Outputs — flat, single-region (ADR-032)
# -----------------------------------------------------------------------------
# This layer's state holds exactly one region's VPC. Downstream layers
# (staging/platform, staging/workloads) read these outputs from the
# region-scoped state key staging/<region>/network/terraform.tfstate.
# -----------------------------------------------------------------------------

output "region" {
  description = "AWS region this network state covers"
  value       = local.region
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR block (allocated by IPAM)"
  value       = module.vpc.vpc_cidr
}

output "public_subnet_ids" {
  description = "Public subnet IDs (in AZ order)"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs (in AZ order)"
  value       = module.vpc.private_subnet_ids
}

output "nat_gateway_id" {
  description = "NAT Gateway ID (single, in AZ-a)"
  value       = module.vpc.nat_gateway_id
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = module.vpc.internet_gateway_id
}

output "availability_zones" {
  description = "Availability Zones used by this VPC"
  value       = module.vpc.availability_zones
}
