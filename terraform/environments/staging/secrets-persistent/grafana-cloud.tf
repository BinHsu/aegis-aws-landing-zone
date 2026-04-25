# -----------------------------------------------------------------------------
# Grafana Cloud persistent SaaS-credential SSM PS shells (ADR-028)
# -----------------------------------------------------------------------------
# Two parameters in this file:
#
#   1. bootstrap-token — Grafana Cloud one-time-display token shown on
#      portal signup. Used by staging/observability's grafana.cloud
#      provider to create downstream tokens (alloy_token, grafana_
#      operator_token). Rotated via Runbook 006 §Token rotation, 30-day
#      cadence. Currently expires 2026-05-23.
#
#      Pre-existing in AWS from prior manual onboarding (Runbook 006
#      §Part 2, executed 2026-04-22). Adopted into this layer's TF state
#      via the import block in imports.tf on first apply.
#
#   2. team-webhooks-slack-aegis — placeholder shell pre-provisioned for
#      aegis-core's GrafanaContactPoint CRD (ldz #126 Coordination
#      Point 1). Real Slack webhook URL is filled by Runbook 006 §Part 4
#      (added by ADR-028 PR) the first time the operator wires Slack
#      alerting. Pre-2026-04-25 this resource lived in
#      staging/observability/tokens.tf with a placeholder value; the
#      teardown that exposed Incident 33 destroyed it (no real value
#      lost). Migrating to this layer prevents the same future loss
#      once a real webhook URL is put.
#
# Both resources use lifecycle.ignore_changes = [value] so subsequent
# `terraform apply` does not clobber the operator-supplied value back to
# the placeholder. Path-B pattern (ADR-028 §Context).
#
# IRSA policy in staging/platform/modules/eks-cluster/external-secrets-iam.tf
# scopes ESO read access via wildcard `/aegis/staging/grafana-cloud/*` —
# unchanged by this layer move. ExternalSecret CRDs that consume these
# parameters remain in staging/observability/ (ADR-028 §ExternalSecret
# CRDs stay in observability).
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# 1. bootstrap-token — Grafana Cloud one-time-display token (Runbook 006 §Part 2)
# -----------------------------------------------------------------------------
# Operator rotates via:
#
#   aws ssm put-parameter \
#     --region eu-central-1 \
#     --name /aegis/staging/grafana-cloud/bootstrap-token \
#     --type SecureString --key-id alias/aegis-staging-secrets \
#     --value '<new bootstrap token from Grafana Cloud portal>' \
#     --overwrite
#
# Forker note: a fresh fork must run Runbook 006 §Part 2 (manual put of
# the bootstrap-token from Grafana Cloud portal) BEFORE the first apply
# of this layer. Without the pre-existing parameter, the import block in
# imports.tf fails with "no SSM parameter found". This is identical to
# the existing onboarding flow — Runbook 006 §Part 2 has always been a
# pre-apply prerequisite — but documented here for ADR-028 audit clarity.
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "bootstrap_token" {
  count = local.grafana_cloud_enabled ? 1 : 0

  name        = "${local.grafana_cloud_ssm_path_prefix}/bootstrap-token"
  description = "Grafana Cloud bootstrap token (one-time-display, 30-day expiry). Operator-managed value; Terraform owns the SecureString shell only. Provisioned by terraform/environments/staging/secrets-persistent/ (ADR-028); consumed via data source in staging/observability/config.tf to authenticate the grafana.cloud provider. Rotation per Runbook 006 §Token rotation."
  type        = "SecureString"
  key_id      = data.aws_kms_alias.secrets[0].target_key_arn
  value       = "placeholder-operator-must-overwrite"

  tags = merge(local.tags, {
    Name = "grafana-cloud-bootstrap-token"
  })

  lifecycle {
    ignore_changes = [value]
  }
}

# -----------------------------------------------------------------------------
# 2. team-webhooks-slack-aegis — Slack webhook URL placeholder (ldz #126 CP1)
# -----------------------------------------------------------------------------
# Multi-key K8s Secret structure: today only `slack-aegis` exists; future
# team onboarding adds keys alongside (e.g. `slack-platform`,
# `slack-billing`). The ExternalSecret in staging/observability/external-
# secrets.tf is the source of truth for which keys exist — adding a team
# = adding a key entry there + a matching SSM PS resource here.
#
# Real value provisioning: Runbook 006 §Part 4 (Slack webhook onboarding,
# added by ADR-028 PR). Today the value is the placeholder string; the
# webhook fires no notifications until a real URL is put. This is by
# design — the layer protects the eventual real URL from teardown loss.
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "team_webhooks_slack_aegis" {
  count = local.grafana_cloud_enabled ? 1 : 0

  name        = "${local.grafana_cloud_ssm_path_prefix}/team-webhooks-slack-aegis"
  description = "Slack webhook URL for aegis team notifications. Operator-managed value; Terraform owns the SecureString shell only. Provisioned by terraform/environments/staging/secrets-persistent/ (ADR-028); consumed by ExternalSecret → K8s Secret `team-webhooks` (key `slack-aegis`) in ns `aegis`, referenced by aegis-core's GrafanaContactPoint CRD (ldz #126). Provisioned per Runbook 006 §Part 4."
  type        = "SecureString"
  key_id      = data.aws_kms_alias.secrets[0].target_key_arn
  value       = "placeholder-operator-must-overwrite"

  tags = merge(local.tags, {
    Name = "grafana-cloud-team-webhooks-slack-aegis"
  })

  lifecycle {
    ignore_changes = [value]
  }
}
