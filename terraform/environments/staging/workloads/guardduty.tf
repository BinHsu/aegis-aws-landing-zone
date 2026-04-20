# -----------------------------------------------------------------------------
# GuardDuty EKS Protection — Phase 4c
# -----------------------------------------------------------------------------
# Enables container-level threat detection for the staging EKS cluster.
# Control Tower may have already created a GuardDuty detector in this
# account — if so, `terraform import aws_guardduty_detector.staging <id>`
# before the first apply.
#
# Two EKS-specific features:
#   - EKS_AUDIT_LOGS: anomaly detection on K8s API audit logs
#     (privilege escalation, anonymous auth, suspicious API calls)
#   - EKS_RUNTIME_MONITORING: container-level runtime agent (crypto mining,
#     reverse shell, DNS exfiltration, file integrity changes)
#
# Cost: ~$1.50/vCPU/month for runtime monitoring (4 vCPU Karpenter cap →
# ~$6/month always-on, but session-based → ~$0.25/session). EKS Audit Log
# monitoring: ~$1/million events/month (negligible at lab scale).
# -----------------------------------------------------------------------------

resource "aws_guardduty_detector" "staging" {
  enable = true

  # Findings published every 15 minutes (shortest available interval).
  # Acceptable for a lab; production would add an EventBridge rule for
  # real-time alerting.
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = {
    Name = "staging-guardduty"
  }
}

resource "aws_guardduty_detector_feature" "eks_audit_log" {
  detector_id = aws_guardduty_detector.staging.id
  name        = "EKS_AUDIT_LOGS"
  status      = "ENABLED"
}

resource "aws_guardduty_detector_feature" "eks_runtime" {
  detector_id = aws_guardduty_detector.staging.id
  name        = "EKS_RUNTIME_MONITORING"
  status      = "ENABLED"

  additional_configuration {
    name   = "EKS_ADDON_MANAGEMENT"
    status = "ENABLED"
  }
}
