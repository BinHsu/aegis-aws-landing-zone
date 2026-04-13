output "vpc_id" {
  description = "Staging VPC ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "Staging VPC CIDR block (allocated by IPAM)"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs (in AZ order)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (in AZ order)"
  value       = aws_subnet.private[*].id
}

output "nat_gateway_id" {
  description = "NAT Gateway ID (single, in AZ-a)"
  value       = aws_nat_gateway.main.id
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.main.id
}

output "availability_zones" {
  description = "Availability Zones used by this VPC"
  value       = local.primary_zones
}
