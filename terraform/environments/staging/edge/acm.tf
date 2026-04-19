# -----------------------------------------------------------------------------
# ACM certificate — TLS for aegis-app.staging.binhsu.org
# -----------------------------------------------------------------------------
# Must live in us-east-1 (AWS constraint — CloudFront only accepts certs
# from that region). Uses the `cloudfront_cert` provider alias declared in
# providers.tf, backed by local.cloudfront_acm_region.
#
# Validation: DNS-based via Route53. Terraform creates the cert, extracts
# the validation CNAMEs from its domain_validation_options, then creates
# matching records in the Route53 zone. ACM polls DNS and marks the cert
# ISSUED. Total time: usually < 5 minutes.
#
# One gotcha: DNS validation records live in Route53, but the CERTIFICATE
# itself lives in us-east-1. Terraform handles the cross-region dance
# cleanly — we just need to pass the right provider to the right resource.
# -----------------------------------------------------------------------------

resource "aws_acm_certificate" "frontend" {
  provider = aws.cloudfront_cert

  domain_name               = local.frontend_hostname
  subject_alternative_names = [] # single-SAN for now; add prod hostname when ldz #79 Q1 lands
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.frontend_hostname}-acm"
  }
}

# -----------------------------------------------------------------------------
# DNS validation records — in Route53 (staging zone), pointing at the
# validation CNAMEs ACM gave us.
# -----------------------------------------------------------------------------

resource "aws_route53_record" "frontend_acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.frontend.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = aws_route53_zone.staging.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true # ACM may request identical records for duplicate certs; idempotent overwrite is safe
}

# -----------------------------------------------------------------------------
# Cert validation — blocks downstream resources until ACM reports ISSUED
# -----------------------------------------------------------------------------

resource "aws_acm_certificate_validation" "frontend" {
  provider = aws.cloudfront_cert

  certificate_arn         = aws_acm_certificate.frontend.arn
  validation_record_fqdns = [for r in aws_route53_record.frontend_acm_validation : r.fqdn]

  timeouts {
    create = "10m"
  }
}
