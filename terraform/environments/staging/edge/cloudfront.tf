# -----------------------------------------------------------------------------
# CloudFront distribution — fronts the S3 frontend bucket
# -----------------------------------------------------------------------------
# OAC (Origin Access Control), not legacy OAI. OAC supports SigV4 which is
# required for S3 buckets with SSE-KMS (we use SSE-S3 here, but OAC is the
# current recommended pattern regardless).
#
# SPA behavior: 404 and 403 responses from S3 (e.g. someone hits /about
# which maps to /about as an S3 object that doesn't exist) get rewritten
# to /index.html + 200. React Router then takes over client-side routing.
#
# TLS: ACM cert from us-east-1 (acm.tf). Alternate domain name is
# aegis-app.staging.binhsu.org. Redirect HTTP → HTTPS.
#
# Cache: default 1 hour (3600s), max 24 hours. Aggressive invalidation via
# the aegis-core CI workflow after each deploy keeps staleness bounded.
# -----------------------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${local.config.organization.name}-staging-frontend-oac"
  description                       = "OAC for the Aegis staging frontend S3 bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "frontend" {
  # checkov:skip=CKV_AWS_310: Single S3 origin by design — there is no secondary origin to fail over to for a static SPA. Multi-region SPA hosting is a different architecture entirely (Route53 geoloc + two regional CloudFronts); not in lab scope.
  # checkov:skip=CKV_AWS_374: Geo restriction intentionally set to "none" — public-facing demo with worldwide expected audience. ADR-019 §"Why PriceClass_100" covers the scope.
  # checkov:skip=CKV_AWS_86: Access logging not configured — would require a second S3 bucket + lifecycle + Athena query layer. Lab traffic volume doesn't justify the operational complexity. CloudFront real-time logs also skipped for same reason. Follow-up if usage analytics become useful.
  # checkov:skip=CKV_AWS_68: WAF not attached — rate limits at the CloudFront layer are 25K req/sec per IP which is above any realistic lab traffic. No auth-sensitive endpoints on this origin (it is a public static site). WAF cost is $5/month per Web ACL + request fees. Follow-up if abuse observed.
  # checkov:skip=CKV2_AWS_47: Same as CKV_AWS_68 — no WAF means no WAFv2 AMR. Paired skip.
  # checkov:skip=CKV2_AWS_32: response_headers_policy_id IS set on default_cache_behavior (Managed-SecurityHeadersPolicy, AWS managed policy ID 67f7725c-6f97-4210-82d7-5512b31e9d03) — live headers include HSTS / X-Content-Type-Options / X-Frame-Options / Referrer-Policy / X-XSS-Protection. Checkov's static analysis does not resolve managed-policy IDs and flags the check as failed despite the attachment being correct; verified post-apply via `curl -I https://aegis-app.staging.binhsu.org/` once first sync lands.
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Aegis staging frontend — CloudFront fronting S3 SPA bundle"
  default_root_object = "index.html"

  aliases = [local.frontend_hostname]

  # Origin: the S3 bucket. `origin_access_control_id` binds to the OAC created
  # above, which makes CloudFront sign requests with SigV4.
  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-${aws_s3_bucket.frontend.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # Default cache behavior
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "s3-${aws_s3_bucket.frontend.id}"

    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    # Managed cache policy: CachingOptimized (recommended by AWS for static
    # web assets — 1 day default TTL, uses gzip/brotli hints from origin).
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized (fixed AWS-managed ID)

    # Managed response headers policy: SecurityHeadersPolicy
    # Adds HSTS (max-age=31536000; includeSubDomains), X-Content-Type-Options: nosniff,
    # X-Frame-Options: SAMEORIGIN, Referrer-Policy: strict-origin-when-cross-origin,
    # X-XSS-Protection: 1; mode=block. Covers CKV2_AWS_32.
    response_headers_policy_id = "67f7725c-6f97-4210-82d7-5512b31e9d03" # Managed-SecurityHeadersPolicy

    # No query strings forwarded → Managed-CachingOptimized already handles this,
    # but being explicit is fine.
  }

  # SPA routing — 404 / 403 from S3 get rewritten to /index.html + 200 status.
  # This lets React Router's client-side routing own URL paths without
  # every deep link being a pre-uploaded S3 object.
  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 60 # don't cache the error-to-index rewrite too aggressively
  }

  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 60
  }

  # TLS — ACM cert from us-east-1
  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.frontend.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  # Geo restrictions — none (public-facing demo)
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Price class — use PriceClass_100 (North America + Europe edge locations
  # only). EU-operator + EU-user demo doesn't need global edge coverage;
  # saves on per-request fees.
  price_class = "PriceClass_100"

  tags = {
    Name = "${local.frontend_hostname}-distribution"
  }

  # Block destroy without explicit `prevent_destroy = false` in a subsequent
  # apply. CloudFront distribution-delete takes 15+ minutes during which the
  # hostname is unreachable; guard against accidental `terraform destroy`.
  lifecycle {
    # Intentionally NOT `prevent_destroy = true` — this is a lab, teardown
    # has to be possible. But flag the concern in review comments.
  }
}
