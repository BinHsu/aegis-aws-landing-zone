# -----------------------------------------------------------------------------
# Providers — two aliases
# -----------------------------------------------------------------------------
# Default provider runs in primary region (e.g. eu-central-1). Hosts:
#   - Route53 hosted zone (Route53 is global but control-plane reads happen here)
#   - S3 frontend bucket (data residency: EU operator → EU bucket)
#   - CloudFront distribution (CloudFront control plane is us-east-1-backed but
#     Terraform accepts provisioning from any region — we pick primary)
#   - IAM role + bucket policy
#
# Aliased `cloudfront_cert` provider runs in us-east-1 — CloudFront REQUIRES
# its ACM certificates to live in us-east-1 specifically. This is an AWS
# service constraint (not a deployment choice), documented in locals as
# `local.cloudfront_acm_region`. Role-based alias label per ADR-018 §3
# amendment (no region strings in .tf — the region VALUE comes from a local
# whose declaration loudly explains the AWS constraint).
# -----------------------------------------------------------------------------

provider "aws" {
  region = local.primary_region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}

provider "aws" {
  alias  = "cloudfront_cert"
  region = local.cloudfront_acm_region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}
