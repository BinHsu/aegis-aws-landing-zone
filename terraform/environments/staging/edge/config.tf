# -----------------------------------------------------------------------------
# Configuration Contract — ADR-004
# -----------------------------------------------------------------------------

locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id     = local.config.accounts.staging.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]

  # -----------------------------------------------------------------------------
  # CloudFront ACM region — AWS service constraint
  # -----------------------------------------------------------------------------
  # CloudFront distributions can only reference ACM certificates from the
  # us-east-1 region. This is AWS-side invariant, not a deployment choice.
  # Exempt from the "zero-tolerance region strings in .tf" rule (CLAUDE.md)
  # because it's in the same category as service principals like
  # `eks.amazonaws.com` — AWS-enforced literal, same across all deployments.
  # -----------------------------------------------------------------------------
  cloudfront_acm_region = "us-east-1"

  # Hostname for the Aegis frontend SPA (per cross-repo #90 / #91 contract).
  # TLS cert + CloudFront distribution + Route53 record all reference this.
  frontend_hostname = "aegis-app.staging.${local.config.domain.name}"

  # Delegated zone — Route53 controls this subdomain; parent `binhsu.org` zone
  # is unrelated (likely on Cloudflare per docs/runbooks/004-dns-delegation-
  # cloudflare-to-route53.md).
  delegated_zone = "staging.${local.config.domain.name}"

  tags = merge(local.config.tags, {
    Environment = "staging"
    Component   = "edge"
  })
}

data "aws_caller_identity" "current" {}

check "expected_account" {
  assert {
    condition     = data.aws_caller_identity.current.account_id == local.account_id
    error_message = "Running against the wrong AWS account (${data.aws_caller_identity.current.account_id}) — staging/edge must be applied with credentials for ${local.account_id} (aegis-staging)."
  }
}
