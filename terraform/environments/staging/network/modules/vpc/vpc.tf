# -----------------------------------------------------------------------------
# Per-region VPC module — ADR-012 topology, parameterized per ADR-018
# -----------------------------------------------------------------------------
# Three-AZ VPC with public/private subnet split, single NAT Gateway (lab
# compromise — production uses 3), Gateway endpoints for S3 + DynamoDB,
# Internet Gateway for public subnets.
#
# CIDR allocated dynamically from the IPAM regional pool passed in via
# `ipam_pool_id`. Specific CIDR is known-after-apply.
#
# This module is invoked once per entry in `eks.<env>.regions[]` — primary
# always, slave_1 conditionally. All resources use the per-region provider
# `aws.this`, so each invocation creates its VPC in the correct region
# without any region string appearing in this file.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# VPC (CIDR from IPAM)
# -----------------------------------------------------------------------------

resource "aws_vpc" "this" {
  provider = aws.this

  ipv4_ipam_pool_id   = var.ipam_pool_id
  ipv4_netmask_length = var.netmask_length

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.env_name}-${var.region_key}-vpc"
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
  provider = aws.this

  count = length(var.zones)

  vpc_id                  = aws_vpc.this.id
  availability_zone       = var.zones[count.index]
  cidr_block              = cidrsubnet(aws_vpc.this.cidr_block, 4, count.index)
  map_public_ip_on_launch = false # Nothing in public subnets needs auto-public-IP

  tags = {
    Name                     = "${var.env_name}-${var.region_key}-public-${var.zones[count.index]}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  provider = aws.this

  count = length(var.zones)

  vpc_id            = aws_vpc.this.id
  availability_zone = var.zones[count.index]
  cidr_block        = cidrsubnet(aws_vpc.this.cidr_block, 3, count.index + 4)

  tags = {
    Name                              = "${var.env_name}-${var.region_key}-private-${var.zones[count.index]}"
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# -----------------------------------------------------------------------------
# Internet Gateway (public egress)
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "this" {
  provider = aws.this

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.env_name}-${var.region_key}-igw"
  }
}

# -----------------------------------------------------------------------------
# NAT Gateway (single, in AZ-a — lab compromise per ADR-012)
# -----------------------------------------------------------------------------

resource "aws_eip" "nat" {
  provider = aws.this

  domain = "vpc"

  tags = {
    Name = "${var.env_name}-${var.region_key}-nat-eip"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  provider = aws.this

  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id # AZ-a

  tags = {
    Name = "${var.env_name}-${var.region_key}-nat-a"
  }

  depends_on = [aws_internet_gateway.this]
}

# -----------------------------------------------------------------------------
# Route Tables — one for all public subnets, one for all private subnets
# -----------------------------------------------------------------------------
# Single private route table is acceptable because the single NAT in AZ-a
# is the only egress target. When production splits to one NAT per AZ,
# split to one private route table per AZ.
# -----------------------------------------------------------------------------

resource "aws_route_table" "public" {
  provider = aws.this

  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.env_name}-${var.region_key}-public-rt"
  }
}

resource "aws_route_table" "private" {
  provider = aws.this

  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name = "${var.env_name}-${var.region_key}-private-rt"
  }
}

resource "aws_route_table_association" "public" {
  provider = aws.this

  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  provider = aws.this

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
#
# The endpoint's service_name includes the region — pulled from the provider
# via data source rather than hardcoded, preserving the "no region strings
# in .tf" rule.
# -----------------------------------------------------------------------------

data "aws_region" "current" {
  provider = aws.this
}

resource "aws_vpc_endpoint" "s3" {
  provider = aws.this

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id, aws_route_table.public.id]

  tags = {
    Name = "${var.env_name}-${var.region_key}-vpce-s3"
  }
}

resource "aws_vpc_endpoint" "dynamodb" {
  provider = aws.this

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id, aws_route_table.public.id]

  tags = {
    Name = "${var.env_name}-${var.region_key}-vpce-dynamodb"
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

resource "aws_default_security_group" "this" {
  provider = aws.this

  vpc_id = aws_vpc.this.id

  # No ingress, no egress — deny all
  tags = {
    Name = "${var.env_name}-${var.region_key}-default-sg-denyall"
  }
}
