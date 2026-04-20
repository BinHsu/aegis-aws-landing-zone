# -----------------------------------------------------------------------------
# Outputs — fork-friendly contract (cross-repo #91 + #95)
# -----------------------------------------------------------------------------
# Names track aegis-core ADR-0027 §"GH Variables over hardcode/Secrets" so
# a fork operator can:
#
#   terraform output -json \
#     | jq -r '.frontend_s3_bucket_name.value' \
#     | xargs -I{} gh variable set FRONTEND_S3_BUCKET --body {} -R <fork>/aegis-core
#
# 1:1 mapping from output name to aegis-core GH Variable name (per #95):
#   frontend_s3_bucket_name              → FRONTEND_S3_BUCKET
#   frontend_cloudfront_distribution_id  → FRONTEND_CLOUDFRONT_DISTRIBUTION_ID
#   frontend_alternate_domain_name       → FRONTEND_DOMAIN
#   frontend_push_role_name              → FRONTEND_PUSH_ROLE_NAME
# -----------------------------------------------------------------------------

output "frontend_s3_bucket_name" {
  description = "S3 bucket ID for frontend SPA assets. aegis-core GH Variable: FRONTEND_S3_BUCKET."
  value       = aws_s3_bucket.frontend.id
}

output "frontend_cloudfront_distribution_id" {
  description = "CloudFront distribution ID. aegis-core GH Variable: FRONTEND_CLOUDFRONT_DISTRIBUTION_ID."
  value       = aws_cloudfront_distribution.frontend.id
}

output "frontend_cloudfront_domain_name" {
  description = "Origin *.cloudfront.net domain. Route53 ALIAS target; NOT the user-facing hostname."
  value       = aws_cloudfront_distribution.frontend.domain_name
}

output "frontend_alternate_domain_name" {
  description = "User-facing hostname (Route53 alias → CloudFront). aegis-core GH Variable: FRONTEND_DOMAIN."
  value       = local.frontend_hostname
}

output "frontend_push_role_arn" {
  description = "OIDC role ARN for aegis-core's release-staging-frontend.yml workflow. Hardcoded in the workflow file env block; no GH Variable needed."
  value       = aws_iam_role.aegis_core_frontend.arn
}

output "frontend_push_role_name" {
  description = "OIDC role name (unqualified). aegis-core GH Variable: FRONTEND_PUSH_ROLE_NAME, used by aws-actions/configure-aws-credentials when it wants just the name-half."
  value       = aws_iam_role.aegis_core_frontend.name
}

# -----------------------------------------------------------------------------
# DNS + ACM outputs — referenced by runbook 004
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# API (gateway ALB) — cross-repo #101
# -----------------------------------------------------------------------------

output "api_hostname" {
  description = "Gateway ALB hostname (aegis-api.staging.<domain>). aegis-core gateway Ingress references this in the `alb.ingress.kubernetes.io/host` / rules[].host field."
  value       = local.api_hostname
}

output "api_acm_certificate_arn" {
  description = "ACM certificate ARN in the primary region for the gateway ALB hostname. aegis-core gateway Ingress consumes this in the `alb.ingress.kubernetes.io/certificate-arn` annotation."
  value       = aws_acm_certificate_validation.api.certificate_arn
}

output "api_route53_creation_hint" {
  description = <<-EOT
    Commands to create the ALIAS record for $api_hostname after ArgoCD has
    synced aegis-core's gateway Ingress and aws-load-balancer-controller has
    provisioned the ALB. The ALB does not exist at this layer's apply time,
    so the record is a manual one-shot (or future: handled by external-dns).

      ALB_DNS=$(kubectl -n aegis get ingress aegis-gateway \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
      ALB_ZONE=$(aws elbv2 describe-load-balancers \
        --query "LoadBalancers[?DNSName=='$ALB_DNS'].CanonicalHostedZoneId | [0]" \
        --output text)
      aws route53 change-resource-record-sets \
        --hosted-zone-id ${aws_route53_zone.staging.zone_id} \
        --change-batch "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"${local.api_hostname}\",\"Type\":\"A\",\"AliasTarget\":{\"HostedZoneId\":\"$ALB_ZONE\",\"DNSName\":\"$ALB_DNS\",\"EvaluateTargetHealth\":false}}}]}"
  EOT
  value       = local.api_hostname
}
