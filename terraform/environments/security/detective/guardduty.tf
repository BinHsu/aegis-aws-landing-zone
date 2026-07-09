# -----------------------------------------------------------------------------
# GuardDuty — org-wide auto-enable (Epic #302 Stage S3, issue #305)
# -----------------------------------------------------------------------------
# Runs in the `security` account, which S2 (#304, PR #311) registered as the
# org delegated administrator for GuardDuty. This layer turns the service ON:
#
#   1. A detector in this (delegated-admin) account.
#   2. Org configuration with `auto_enable_organization_members = "ALL"` —
#      AWS auto-creates a detector in every EXISTING and future member
#      account (this is the "member account shows an auto-created detector"
#      validation in #305).
#   3. Explicit DISABLED/NONE feature blocks for every paid add-on, at both
#      the detector level (this account) and the org level (member accounts).
#      Frugal posture per epic #302: foundational data sources only
#      (CloudTrail management events + VPC Flow Logs + DNS logs).
#
# COST: foundational analysis bills per CloudTrail event analyzed
# ($0.0000046/event in eu-central-1) and per GB of VPC Flow/DNS logs ($1.15/GB
# first tier; ~zero while no VPCs exist). Every account gets a one-time 30-day
# free trial. See docs/finops.md "Detective baseline" and ADR-023.
#
# WHY the paid add-ons are disabled EXPLICITLY rather than by omission:
# CreateDetector historically defaults S3 Protection ON for first-time
# detectors; omission would silently opt into a paid feature. The issue (#305)
# names S3 / EKS / Malware / RDS Protection; LAMBDA_NETWORK_LOGS and
# RUNTIME_MONITORING are the two remaining billable features in the current
# feature set, so they are pinned off too — same frugal-posture logic, made
# visible here rather than left to AWS defaults. (EKS_RUNTIME_MONITORING is
# omitted deliberately: it is superseded by RUNTIME_MONITORING and AWS rejects
# configuring both.)
#
# WHY the feature resources are depends_on-chained: each feature resource
# read-modify-writes shared detector/org configuration; letting Terraform run
# all of them in parallel invites ConcurrentModificationException-shaped API
# errors. The chain serializes them at negligible wall-clock cost.
# -----------------------------------------------------------------------------

resource "aws_guardduty_detector" "org" {
  count = var.detective_enabled ? 1 : 0

  enable = true
  # Slowest cadence — findings export frequency has no effect on detection
  # latency in-console, only on EventBridge/S3 export; slowest is the frugal
  # default for a lab with no downstream consumer.
  finding_publishing_frequency = "SIX_HOURS"

  tags = local.tags
}

# --- Detector-level paid features: pinned DISABLED in this account -----------

resource "aws_guardduty_detector_feature" "s3_data_events" {
  count = var.detective_enabled ? 1 : 0

  detector_id = aws_guardduty_detector.org[count.index].id
  name        = "S3_DATA_EVENTS"
  status      = "DISABLED"
}

resource "aws_guardduty_detector_feature" "eks_audit_logs" {
  count = var.detective_enabled ? 1 : 0

  detector_id = aws_guardduty_detector.org[count.index].id
  name        = "EKS_AUDIT_LOGS"
  status      = "DISABLED"

  depends_on = [aws_guardduty_detector_feature.s3_data_events]
}

resource "aws_guardduty_detector_feature" "ebs_malware_protection" {
  count = var.detective_enabled ? 1 : 0

  detector_id = aws_guardduty_detector.org[count.index].id
  name        = "EBS_MALWARE_PROTECTION"
  status      = "DISABLED"

  depends_on = [aws_guardduty_detector_feature.eks_audit_logs]
}

resource "aws_guardduty_detector_feature" "rds_login_events" {
  count = var.detective_enabled ? 1 : 0

  detector_id = aws_guardduty_detector.org[count.index].id
  name        = "RDS_LOGIN_EVENTS"
  status      = "DISABLED"

  depends_on = [aws_guardduty_detector_feature.ebs_malware_protection]
}

resource "aws_guardduty_detector_feature" "lambda_network_logs" {
  count = var.detective_enabled ? 1 : 0

  detector_id = aws_guardduty_detector.org[count.index].id
  name        = "LAMBDA_NETWORK_LOGS"
  status      = "DISABLED"

  depends_on = [aws_guardduty_detector_feature.rds_login_events]
}

resource "aws_guardduty_detector_feature" "runtime_monitoring" {
  count = var.detective_enabled ? 1 : 0

  detector_id = aws_guardduty_detector.org[count.index].id
  name        = "RUNTIME_MONITORING"
  status      = "DISABLED"

  depends_on = [aws_guardduty_detector_feature.lambda_network_logs]
}

# --- Org configuration: auto-enable ALL members, foundational only -----------

resource "aws_guardduty_organization_configuration" "org" {
  count = var.detective_enabled ? 1 : 0

  detector_id                      = aws_guardduty_detector.org[count.index].id
  auto_enable_organization_members = "ALL"

  # Serialize behind the detector-feature updates (same underlying detector).
  depends_on = [aws_guardduty_detector_feature.runtime_monitoring]
}

# --- Org-level paid features: pinned NONE for member accounts ----------------

resource "aws_guardduty_organization_configuration_feature" "s3_data_events" {
  count = var.detective_enabled ? 1 : 0

  detector_id = aws_guardduty_detector.org[count.index].id
  name        = "S3_DATA_EVENTS"
  auto_enable = "NONE"

  depends_on = [aws_guardduty_organization_configuration.org]
}

resource "aws_guardduty_organization_configuration_feature" "eks_audit_logs" {
  count = var.detective_enabled ? 1 : 0

  detector_id = aws_guardduty_detector.org[count.index].id
  name        = "EKS_AUDIT_LOGS"
  auto_enable = "NONE"

  depends_on = [aws_guardduty_organization_configuration_feature.s3_data_events]
}

resource "aws_guardduty_organization_configuration_feature" "ebs_malware_protection" {
  count = var.detective_enabled ? 1 : 0

  detector_id = aws_guardduty_detector.org[count.index].id
  name        = "EBS_MALWARE_PROTECTION"
  auto_enable = "NONE"

  depends_on = [aws_guardduty_organization_configuration_feature.eks_audit_logs]
}

resource "aws_guardduty_organization_configuration_feature" "rds_login_events" {
  count = var.detective_enabled ? 1 : 0

  detector_id = aws_guardduty_detector.org[count.index].id
  name        = "RDS_LOGIN_EVENTS"
  auto_enable = "NONE"

  depends_on = [aws_guardduty_organization_configuration_feature.ebs_malware_protection]
}

resource "aws_guardduty_organization_configuration_feature" "lambda_network_logs" {
  count = var.detective_enabled ? 1 : 0

  detector_id = aws_guardduty_detector.org[count.index].id
  name        = "LAMBDA_NETWORK_LOGS"
  auto_enable = "NONE"

  depends_on = [aws_guardduty_organization_configuration_feature.rds_login_events]
}

resource "aws_guardduty_organization_configuration_feature" "runtime_monitoring" {
  count = var.detective_enabled ? 1 : 0

  detector_id = aws_guardduty_detector.org[count.index].id
  name        = "RUNTIME_MONITORING"
  auto_enable = "NONE"

  depends_on = [aws_guardduty_organization_configuration_feature.lambda_network_logs]
}
