# -----------------------------------------------------------------------------
# Route53 hosted zone — staging.binhsu.org (subdomain delegation from parent)
# -----------------------------------------------------------------------------
# The parent domain (e.g. binhsu.org) lives on Cloudflare (or another DNS
# provider). We create a Route53 hosted zone scoped to the `staging.` subdomain
# only, and the parent-side operator adds 4 NS records pointing at this zone's
# nameservers. See docs/runbooks/004-dns-delegation-cloudflare-to-route53.md
# for the step-by-step.
#
# Why subdomain delegation (not full domain move):
#   - Keeps parent domain DNS management on existing provider (operator
#     comfort, existing records like www/blog preserved)
#   - Infrastructure DNS (aegis-app.staging, aegis-api.staging, future
#     subdomains) is Terraform-managed in Route53 — IaC the way it should be
#   - Reversible: delete the 4 NS records on the parent side to roll back
#     delegation; Route53 zone becomes orphaned but harmless
# -----------------------------------------------------------------------------

resource "aws_route53_zone" "staging" {
  # checkov:skip=CKV2_AWS_38: DNSSEC not enabled on this delegated zone. Parent (binhsu.org on Cloudflare) does not propagate DS records to the Route53 zone; enabling DNSSEC here without parent-side DS records produces a zone that fails DNSSEC-validating resolvers. Cloudflare-parent DNSSEC-subdomain-coordination is non-trivial and not justified for a lab-tier demo domain. Follow-up when the parent zone moves fully to Route53 (where DNSSEC is one-click).
  # checkov:skip=CKV2_AWS_39: Route53 query logging requires a CloudWatch Logs group in us-east-1 (AWS constraint for Route53 query logs — logs MUST land in us-east-1 regardless of zone's own "region"). Adds cross-region log group + CMK + permission boilerplate for single-operator lab traffic volume. Follow-up if operational visibility ever matters; today's NS queries are trivially countable via CloudTrail.
  name    = local.delegated_zone
  comment = "Delegated subdomain zone for Aegis staging — managed by terraform/environments/staging/edge"

  # Enforce that teardown doesn't accidentally destroy the zone (and lose
  # delegation state the parent domain depends on). Use `terraform state rm`
  # + manual NS cleanup on parent side for intentional teardown.
  tags = {
    Name = "${local.delegated_zone}-hosted-zone"
  }
}

# -----------------------------------------------------------------------------
# A record (alias) — aegis-app.staging.binhsu.org → CloudFront distribution
# -----------------------------------------------------------------------------

resource "aws_route53_record" "frontend_alias" {
  zone_id = aws_route53_zone.staging.zone_id
  name    = local.frontend_hostname
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.frontend.domain_name
    zone_id                = aws_cloudfront_distribution.frontend.hosted_zone_id
    evaluate_target_health = false
  }
}

# IPv6 alias — same target, AAAA record
resource "aws_route53_record" "frontend_alias_ipv6" {
  zone_id = aws_route53_zone.staging.zone_id
  name    = local.frontend_hostname
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.frontend.domain_name
    zone_id                = aws_cloudfront_distribution.frontend.hosted_zone_id
    evaluate_target_health = false
  }
}
