# -----------------------------------------------------------------------------
# ACM certificate — TLS for aegis-api.staging.binhsu.org (gateway ALB)
# -----------------------------------------------------------------------------
# Unlike the frontend cert (us-east-1, CloudFront-bound), this cert lives in
# the primary region because its consumer is an ALB provisioned by
# aws-load-balancer-controller from aegis-core's gateway Ingress — ALBs
# require a regional ACM cert.
#
# Validation: DNS-based via the delegated Route53 zone (aws_route53_zone.staging
# in route53.tf — managed by this layer). No cross-region dance needed since
# both cert and zone are reachable from the default provider.
#
# Cross-repo contract: ldz #101 (ACM + Route53 request from aegis-core).
# aegis-core's gateway Ingress references output.api_acm_certificate_arn
# via the `alb.ingress.kubernetes.io/certificate-arn` annotation.
#
# Route53 ALIAS record for the hostname itself is NOT created here — the ALB
# DNS name does not exist at this layer's apply time (LBC creates the ALB
# only after aegis-core's Ingress syncs, which happens post-apply). Record
# creation is documented as a manual one-shot in the PR description and in
# cross-repo #101, or alternatively covered by external-dns (not installed
# as of this PR). See the outputs.tf `api_route53_creation_hint` output for
# the exact command.
# -----------------------------------------------------------------------------

resource "aws_acm_certificate" "api" {
  domain_name               = local.api_hostname
  subject_alternative_names = [] # single-SAN for now
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.api_hostname}-acm"
  }
}

# -----------------------------------------------------------------------------
# DNS validation records — in the delegated Route53 zone
# -----------------------------------------------------------------------------

resource "aws_route53_record" "api_acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.api.domain_validation_options :
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
  allow_overwrite = true
}

# -----------------------------------------------------------------------------
# Cert validation — blocks downstream consumers (aegis-core Ingress) until
# ACM reports ISSUED. Without this, the ALB would provision with a cert that
# is still PENDING_VALIDATION and terminate TLS incorrectly.
# -----------------------------------------------------------------------------

resource "aws_acm_certificate_validation" "api" {
  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [for r in aws_route53_record.api_acm_validation : r.fqdn]

  timeouts {
    create = "10m"
  }
}
