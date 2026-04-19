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
