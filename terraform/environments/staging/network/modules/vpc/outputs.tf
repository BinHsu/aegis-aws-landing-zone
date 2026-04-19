output "vpc_id" {
  description = "VPC ID for this region"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block (allocated by IPAM)"
  value       = aws_vpc.this.cidr_block
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
  value       = aws_nat_gateway.this.id
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.this.id
}

output "availability_zones" {
  description = "Availability Zones used by this VPC"
  value       = var.zones
}

output "region_name" {
  description = "AWS region name for this VPC"
  value       = var.region_name
}
