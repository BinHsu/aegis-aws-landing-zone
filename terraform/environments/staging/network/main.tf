# -----------------------------------------------------------------------------
# Staging VPC — Phase 3b per ADR-012
# -----------------------------------------------------------------------------
# Three-AZ VPC with public/private subnet split, single NAT Gateway (lab
# compromise — production uses 3), Gateway endpoints for S3 + DynamoDB,
# Internet Gateway for public subnets.
#
# CIDR allocated dynamically from the shared/ipam regional pool (RFC1918
# 10.0.0.0/12 for eu-central-1). Specific CIDR is known-after-apply.
#
# VPC Flow Logs: see flow-logs.tf (added in Phase 4b).
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# VPC (CIDR from IPAM)
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  ipv4_ipam_pool_id   = data.terraform_remote_state.shared_ipam.outputs.primary_pool_id
  ipv4_netmask_length = local.vpc_config.netmask_length

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "staging-vpc"
  }
}

# -----------------------------------------------------------------------------
# Subnets — 3 public (/24) + 3 private (/23) across 3 AZs
# -----------------------------------------------------------------------------
# Sizing from a /20 VPC:
#   Public  /24 × 3 = 768 IPs   (indices 0,1,2 of the /24 split)
#   Private /23 × 3 = 1,536 IPs (indices 4,5,6 of the /23 split)
#   Unused: 1,792 IPs (room for growth without resize)
# -----------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count = length(local.primary_zones)

  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.primary_zones[count.index]
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 4, count.index)
  map_public_ip_on_launch = false # Nothing in public subnets needs auto-public-IP

  tags = {
    Name                     = "staging-public-${local.primary_zones[count.index]}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count = length(local.primary_zones)

  vpc_id            = aws_vpc.main.id
  availability_zone = local.primary_zones[count.index]
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 3, count.index + 4)

  tags = {
    Name                              = "staging-private-${local.primary_zones[count.index]}"
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# -----------------------------------------------------------------------------
# Internet Gateway (public egress)
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "staging-igw"
  }
}

# -----------------------------------------------------------------------------
# NAT Gateway (single, in AZ-a — lab compromise per ADR-012)
# -----------------------------------------------------------------------------

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "staging-nat-eip"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id # AZ-a

  tags = {
    Name = "staging-nat-a"
  }

  depends_on = [aws_internet_gateway.main]
}

# -----------------------------------------------------------------------------
# Route Tables — one for all public subnets, one for all private subnets
# -----------------------------------------------------------------------------
# Single private route table is acceptable because the single NAT in AZ-a
# is the only egress target. When production splits to one NAT per AZ,
# split to one private route table per AZ.
# -----------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "staging-public-rt"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "staging-private-rt"
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# -----------------------------------------------------------------------------
# Gateway VPC Endpoints (free — S3 and DynamoDB)
# -----------------------------------------------------------------------------
# Gateway endpoints attach to route tables and route traffic to AWS services
# over the private network. No data processing charges, no hourly fees.
# S3 endpoint is the big cost-saver — ECR image layers traverse S3 internally,
# routing them through the Gateway endpoint offloads NAT data transfer.
# -----------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${local.primary_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id, aws_route_table.public.id]

  tags = {
    Name = "staging-vpce-s3"
  }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${local.primary_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id, aws_route_table.public.id]

  tags = {
    Name = "staging-vpce-dynamodb"
  }
}

# -----------------------------------------------------------------------------
# Default security group — deny all traffic (CKV2_AWS_12)
# -----------------------------------------------------------------------------
# AWS creates a default security group when the VPC is created. By default
# it allows all traffic within the group, which is an implicit "anything in
# this VPC can talk to anything else in this SG." Best practice is to
# explicitly empty the default SG so nothing uses it accidentally — every
# resource must attach to a named security group with explicit rules.
# -----------------------------------------------------------------------------

resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id

  # No ingress, no egress — deny all
  tags = {
    Name = "staging-default-sg-denyall"
  }
}

check "ipam_pool_available" {
  assert {
    condition     = data.terraform_remote_state.shared_ipam.outputs.primary_pool_id != ""
    error_message = "shared/ipam has not been applied. Apply shared/ipam before staging/network."
  }
}
