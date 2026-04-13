output "ipam_id" {
  description = "IPAM resource ID"
  value       = aws_vpc_ipam.main.id
}

output "ipam_arn" {
  description = "IPAM resource ARN"
  value       = aws_vpc_ipam.main.arn
}

output "primary_pool_id" {
  description = "Regional IPAM pool ID for primary region"
  value       = aws_vpc_ipam_pool.primary.id
}

output "primary_pool_arn" {
  description = "Regional IPAM pool ARN for primary region"
  value       = aws_vpc_ipam_pool.primary.arn
}

output "dr_pool_id" {
  description = "Regional IPAM pool ID for DR region"
  value       = aws_vpc_ipam_pool.dr.id
}

output "dr_pool_arn" {
  description = "Regional IPAM pool ARN for DR region"
  value       = aws_vpc_ipam_pool.dr.arn
}

output "ram_resource_share_arn" {
  description = "RAM share ARN for IPAM pools"
  value       = aws_ram_resource_share.ipam_pools.arn
}
