# -----------------------------------------------------------------------------
# Outputs consumed by cross-repo #91 (aegis-core Phase 4a-5 CI wiring)
# -----------------------------------------------------------------------------

output "frontend_bucket_name" {
  description = "S3 bucket name for frontend SPA assets. aegis-core sets as GitHub Actions secret AEGIS_FRONTEND_BUCKET_STAGING."
  value       = aws_s3_bucket.frontend.id
}

output "frontend_distribution_id" {
  description = "CloudFront distribution ID. aegis-core sets as GitHub Actions secret AEGIS_FRONTEND_DISTRIBUTION_ID_STAGING."
  value       = aws_cloudfront_distribution.frontend.id
}

output "frontend_distribution_domain_name" {
  description = "CloudFront distribution's *.cloudfront.net domain (not the user-facing alias)."
  value       = aws_cloudfront_distribution.frontend.domain_name
}

output "frontend_hostname" {
  description = "User-facing hostname (Route53 alias → CloudFront)."
  value       = local.frontend_hostname
}

output "aegis_core_frontend_role_arn" {
  description = "OIDC role ARN for aegis-core's release-staging-frontend.yml workflow. Hardcoded in the workflow file env block; no GH secret needed."
  value       = aws_iam_role.aegis_core_frontend.arn
}

output "delegated_zone" {
  description = "Delegated Route53 zone name (staging.<domain>)."
  value       = local.delegated_zone
}

output "delegated_zone_id" {
  description = "Route53 hosted zone ID for the delegated staging subdomain."
  value       = aws_route53_zone.staging.zone_id
}

output "delegated_zone_nameservers" {
  description = <<-EOT
    The 4 authoritative nameservers for the delegated staging subdomain.
    PASTE THESE AS NS RECORDS on the parent-domain DNS provider (e.g.
    Cloudflare) — see docs/runbooks/004-dns-delegation-cloudflare-to-route53.md.
    Until delegation is live, ACM validation will fail and nothing reachable
    via the frontend hostname will resolve.
  EOT
  value       = aws_route53_zone.staging.name_servers
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN in us-east-1 for the frontend hostname."
  value       = aws_acm_certificate.frontend.arn
}
