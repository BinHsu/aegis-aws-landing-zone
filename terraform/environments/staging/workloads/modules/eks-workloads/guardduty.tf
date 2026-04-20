# -----------------------------------------------------------------------------
# GuardDuty EKS Protection — ADR-016 (admission control + posture) + Phase 4c
# -----------------------------------------------------------------------------
# Per-region detector. Each cluster's slot creates one detector in its own
# region (aws.this provider handles region scoping).
#
# Control Tower may auto-enable a detector in the account before this layer
# runs. Verified empty in both eu-central-1 and eu-west-1 at PR time
# (`aws guardduty list-detectors` → DetectorIds: []), so the apply path is
# create. If a future apply hits "detector already exists", import the
# existing one before retry:
#
#   terraform import \
#     'module.workloads_<slot>.aws_guardduty_detector.staging' <detector-id>
#
# Two EKS-specific features:
#   - EKS_AUDIT_LOGS: anomaly detection on K8s API audit logs (privilege
#     escalation, anonymous auth, suspicious API calls)
#   - EKS_RUNTIME_MONITORING: container-level runtime agent (crypto mining,
#     reverse shell, DNS exfiltration, file integrity changes). The
#     EKS_ADDON_MANAGEMENT additional config tells GuardDuty to install
#     and update the runtime agent as an EKS managed addon.
#
# Cost (per cluster): ~$1.50/vCPU/month for runtime monitoring (4 vCPU
# Karpenter cap → ~$6/month always-on, but session-based → ~$0.25/session).
# EKS Audit Log monitoring: ~$1/million events/month (negligible at lab
# scale). Multi-region doubles the figures.
# -----------------------------------------------------------------------------

resource "aws_guardduty_detector" "staging" {
  provider = aws.this

  enable = true

  # Findings published every 15 minutes (shortest available interval).
  # Acceptable for a lab; production would add an EventBridge rule for
  # real-time alerting.
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = merge(var.tags, {
    Name       = "${var.cluster_name}-guardduty"
    RegionRole = var.region_key
  })
}

resource "aws_guardduty_detector_feature" "eks_audit_logs" {
  provider = aws.this

  detector_id = aws_guardduty_detector.staging.id
  name        = "EKS_AUDIT_LOGS"
  status      = "ENABLED"
}

resource "aws_guardduty_detector_feature" "eks_runtime" {
  provider = aws.this

  detector_id = aws_guardduty_detector.staging.id
  name        = "EKS_RUNTIME_MONITORING"
  status      = "ENABLED"

  additional_configuration {
    name   = "EKS_ADDON_MANAGEMENT"
    status = "ENABLED"
  }
}
