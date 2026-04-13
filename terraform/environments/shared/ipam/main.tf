# -----------------------------------------------------------------------------
# AWS IPAM — Cross-Account CIDR Allocation (ADR-004 Mode B, ADR-012)
# -----------------------------------------------------------------------------
# Hierarchy:
#   IPAM (private scope)
#     └── Top-level pool (10.0.0.0/8)
#           ├── Regional pool eu-central-1 (10.0.0.0/12)  ← shared via RAM
#           └── Regional pool eu-west-1    (10.16.0.0/12) ← shared via RAM
#
# Workload accounts (staging, prod, future sandboxes) allocate VPC CIDRs from
# the regional pools. IPAM enforces non-overlap at the API level — no human
# CIDR planning required.
#
# Cost: IPAM Advanced Tier — $0.0027/IP/hour for active IPs allocated by IPAM.
# Idle pools cost $0. A staging /20 VPC running 24/7 costs ~$8/month;
# per-session (4-hour) cost is ~$0.04. See ADR-004 + ADR-012.
# -----------------------------------------------------------------------------

resource "aws_vpc_ipam" "main" {
  description = "Aegis organization-wide IPAM for VPC CIDR allocation"
  tier        = "advanced"  # Required for cross-account RAM sharing

  dynamic "operating_regions" {
    for_each = local.operating_regions
    content {
      region_name = operating_regions.value
    }
  }
}

# -----------------------------------------------------------------------------
# Top-level pool — 10.0.0.0/8, source for all regional pools
# -----------------------------------------------------------------------------

resource "aws_vpc_ipam_pool" "top" {
  description    = "Top-level pool — entire RFC1918 10.0.0.0/8 space"
  address_family = "ipv4"
  ipam_scope_id  = aws_vpc_ipam.main.private_default_scope_id
  # Top-level pool is not locale-locked; regional pools cascade from it
}

resource "aws_vpc_ipam_pool_cidr" "top" {
  ipam_pool_id = aws_vpc_ipam_pool.top.id
  cidr         = local.top_cidr
}

# -----------------------------------------------------------------------------
# Regional pool: eu-central-1 (primary)
# -----------------------------------------------------------------------------

resource "aws_vpc_ipam_pool" "primary" {
  description         = "Regional pool — ${local.primary_region}"
  address_family      = "ipv4"
  ipam_scope_id       = aws_vpc_ipam.main.private_default_scope_id
  source_ipam_pool_id = aws_vpc_ipam_pool.top.id
  locale              = local.primary_region
  auto_import         = false
}

resource "aws_vpc_ipam_pool_cidr" "primary" {
  ipam_pool_id = aws_vpc_ipam_pool.primary.id
  cidr         = local.pool_cidrs[local.primary_region].cidr

  depends_on = [aws_vpc_ipam_pool_cidr.top]
}

# -----------------------------------------------------------------------------
# Regional pool: eu-west-1 (DR)
# -----------------------------------------------------------------------------

resource "aws_vpc_ipam_pool" "dr" {
  description         = "Regional pool — ${local.dr_region}"
  address_family      = "ipv4"
  ipam_scope_id       = aws_vpc_ipam.main.private_default_scope_id
  source_ipam_pool_id = aws_vpc_ipam_pool.top.id
  locale              = local.dr_region
  auto_import         = false
}

resource "aws_vpc_ipam_pool_cidr" "dr" {
  ipam_pool_id = aws_vpc_ipam_pool.dr.id
  cidr         = local.pool_cidrs[local.dr_region].cidr

  depends_on = [aws_vpc_ipam_pool_cidr.top]
}

# -----------------------------------------------------------------------------
# RAM Sharing — make regional pools available to all org member accounts
# -----------------------------------------------------------------------------
# Without RAM sharing, only the shared account can allocate from these pools.
# Sharing org-wide means staging/prod/future accounts can request CIDR
# allocations directly via aws_vpc_ipam_pool_cidr_allocation.
#
# Pool-level sharing (not VPC-level) — accounts get the right to draw from
# the pool, IPAM still enforces non-overlap centrally.
# -----------------------------------------------------------------------------

resource "aws_ram_resource_share" "ipam_pools" {
  name                      = "aegis-ipam-pools"
  allow_external_principals = false
}

resource "aws_ram_principal_association" "org" {
  resource_share_arn = aws_ram_resource_share.ipam_pools.arn
  principal          = local.org_arn
}

resource "aws_ram_resource_association" "primary_pool" {
  resource_share_arn = aws_ram_resource_share.ipam_pools.arn
  resource_arn       = aws_vpc_ipam_pool.primary.arn
}

resource "aws_ram_resource_association" "dr_pool" {
  resource_share_arn = aws_ram_resource_share.ipam_pools.arn
  resource_arn       = aws_vpc_ipam_pool.dr.arn
}

data "aws_caller_identity" "current" {}

check "config_account_id_not_empty" {
  assert {
    condition     = local.account_id != ""
    error_message = "accounts.shared.id in landing-zone.yaml is empty."
  }
}
