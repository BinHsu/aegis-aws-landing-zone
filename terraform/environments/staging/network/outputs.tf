# -----------------------------------------------------------------------------
# Outputs — shape is per-region maps, keyed by role-based slot name
# -----------------------------------------------------------------------------
# Downstream consumers (staging/platform, staging/workloads) read these
# maps and index by the same slot name. Adding a third region means adding
# a new slot, which would extend the map keys automatically.
#
# Backward-compat shims (flat primary-region outputs) are provided for
# consumers that have not yet been multi-region-aware. Remove when all
# consumers read from the map.
# -----------------------------------------------------------------------------

output "vpcs" {
  description = "Per-region VPC details, keyed by slot name (primary, slave_1, ...)"
  value = merge(
    {
      primary = {
        vpc_id              = module.vpc_primary.vpc_id
        vpc_cidr            = module.vpc_primary.vpc_cidr
        public_subnet_ids   = module.vpc_primary.public_subnet_ids
        private_subnet_ids  = module.vpc_primary.private_subnet_ids
        nat_gateway_id      = module.vpc_primary.nat_gateway_id
        internet_gateway_id = module.vpc_primary.internet_gateway_id
        availability_zones  = module.vpc_primary.availability_zones
        region_name         = module.vpc_primary.region_name
      }
    },
    length(module.vpc_slave_1) > 0 ? {
      slave_1 = {
        vpc_id              = module.vpc_slave_1[0].vpc_id
        vpc_cidr            = module.vpc_slave_1[0].vpc_cidr
        public_subnet_ids   = module.vpc_slave_1[0].public_subnet_ids
        private_subnet_ids  = module.vpc_slave_1[0].private_subnet_ids
        nat_gateway_id      = module.vpc_slave_1[0].nat_gateway_id
        internet_gateway_id = module.vpc_slave_1[0].internet_gateway_id
        availability_zones  = module.vpc_slave_1[0].availability_zones
        region_name         = module.vpc_slave_1[0].region_name
      }
    } : {}
  )
}

# -----------------------------------------------------------------------------
# Backward-compat primary-region outputs
# -----------------------------------------------------------------------------
# Platform + workloads layers currently read these flat outputs. Keeping
# them pointing at the primary VPC preserves compatibility while we refactor
# the consumers to read from `vpcs` map. Delete once consumers are migrated.
# -----------------------------------------------------------------------------

output "vpc_id" {
  description = "Primary region VPC ID (backward-compat)"
  value       = module.vpc_primary.vpc_id
}

output "vpc_cidr" {
  description = "Primary region VPC CIDR block (backward-compat)"
  value       = module.vpc_primary.vpc_cidr
}

output "public_subnet_ids" {
  description = "Primary region public subnet IDs (backward-compat)"
  value       = module.vpc_primary.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Primary region private subnet IDs (backward-compat)"
  value       = module.vpc_primary.private_subnet_ids
}

output "nat_gateway_id" {
  description = "Primary region NAT Gateway ID (backward-compat)"
  value       = module.vpc_primary.nat_gateway_id
}

output "internet_gateway_id" {
  description = "Primary region Internet Gateway ID (backward-compat)"
  value       = module.vpc_primary.internet_gateway_id
}

output "availability_zones" {
  description = "Primary region Availability Zones (backward-compat)"
  value       = module.vpc_primary.availability_zones
}
