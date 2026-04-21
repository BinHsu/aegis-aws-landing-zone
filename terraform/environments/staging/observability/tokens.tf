# -----------------------------------------------------------------------------
# Grafana Cloud downstream tokens + SSM PS writeback (ADR-022)
# -----------------------------------------------------------------------------
# Three chains in this file:
#
#   1. Alloy — Cloud Access Policy (metrics:write, logs:write) scoped to this
#      stack's realm only, plus a token with 90-day expiry. Token value is
#      written to SSM PS for External Secrets Operator to sync into K8s.
#
#   2. grafana-operator — stack-level Service Account with Admin role, plus
#      a token with 90-day expiry. Stack Admin is required because
#      grafana-operator reconciles dashboards, contact points, notification
#      policies across the stack (ADR-023 §Decision — platform ownership of
#      the Grafana CRD). Token value written to SSM PS.
#
#   3. team-webhooks-slack-aegis — a placeholder SSM PS parameter. Terraform
#      creates the parameter with a dummy value; the operator fills the real
#      Slack webhook URL out-of-band via AWS CLI. `lifecycle.ignore_changes`
#      on `value` prevents Terraform from clobbering the operator-supplied
#      secret on subsequent applies. This fulfills ldz #126 Coordination
#      Point 1 for aegis-core (key exists in `team-webhooks` Secret by the
#      time aegis-core's GrafanaContactPoint CRD arrives).
#
# Why two different resource families for the two tokens:
#   - Alloy needs a stack-realm Cloud Access Policy — metrics/logs push
#     credentials live at the Cloud (org) API layer, not inside the stack.
#   - grafana-operator needs a stack Service Account — the Grafana API it
#     talks to (dashboards, alerting) is per-stack and authenticated by an
#     SA token minted inside the stack.
# Both are provisioned via the `cloud`-aliased grafana/grafana provider
# using the one-time bootstrap token in SSM PS.
#
# Token lifecycle: 90-day expiry per Runbook 006 §Token rotation. Rotation
# is a Terraform operation — edit `seconds_to_live` / `expires_at`, apply,
# External Secrets picks up the new values within its refresh interval.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Stack lookup — resolves the stack's region_slug for access-policy realm
# -----------------------------------------------------------------------------
# grafana_cloud_access_policy.realm needs the stack identifier. We look up
# the stack by its slug (from config.grafana_cloud.org_slug) so the realm
# entry is construction-safe against region drift (the stack's region is
# locked at creation and cannot change, but making the relationship data-
# sourced keeps the resource schema honest).
# -----------------------------------------------------------------------------

data "grafana_cloud_stack" "this" {
  count = local.observability_enabled ? 1 : 0

  provider = grafana.cloud

  slug = local.grafana_cloud.org_slug
}

# -----------------------------------------------------------------------------
# Alloy — Cloud Access Policy + token
# -----------------------------------------------------------------------------

resource "grafana_cloud_access_policy" "alloy" {
  count = local.observability_enabled ? 1 : 0

  provider = grafana.cloud

  region       = data.grafana_cloud_stack.this[0].region_slug
  name         = "aegis-staging-alloy"
  display_name = "Alloy — metrics and logs push from aegis-staging clusters"

  scopes = ["metrics:write", "logs:write"]

  realm {
    type       = "stack"
    identifier = data.grafana_cloud_stack.this[0].id
  }
}

resource "grafana_cloud_access_policy_token" "alloy" {
  count = local.observability_enabled ? 1 : 0

  provider = grafana.cloud

  region           = data.grafana_cloud_stack.this[0].region_slug
  access_policy_id = grafana_cloud_access_policy.alloy[0].policy_id
  name             = "aegis-staging-alloy"
  display_name     = "Alloy 90-day rotating token"
  # 90-day expiry per Runbook 006 §Token rotation. Bump this timestamp on
  # rotation — new token value materialises and SSM PS updates in-place.
  expires_at = "2026-07-20T00:00:00Z"
}

# -----------------------------------------------------------------------------
# grafana-operator — Stack Service Account + token
# -----------------------------------------------------------------------------

resource "grafana_cloud_stack_service_account" "grafana_operator" {
  count = local.observability_enabled ? 1 : 0

  provider = grafana.cloud

  stack_slug = local.grafana_cloud.org_slug
  name       = "grafana-operator"
  role       = "Admin"
}

resource "grafana_cloud_stack_service_account_token" "grafana_operator" {
  count = local.observability_enabled ? 1 : 0

  provider = grafana.cloud

  stack_slug         = local.grafana_cloud.org_slug
  service_account_id = grafana_cloud_stack_service_account.grafana_operator[0].id
  name               = "grafana-operator-terraform"
  # 90 days = 7,776,000 seconds. Matches Alloy's rotation cadence.
  seconds_to_live = 7776000
}

# -----------------------------------------------------------------------------
# SSM PS writeback — downstream tokens
# -----------------------------------------------------------------------------
# Each token is stored as a SecureString encrypted with the shared secrets
# CMK (alias/aegis-staging-secrets). External Secrets Operator (installed in
# staging/platform) reads these parameters via the aegis-ssm
# ClusterSecretStore and reconciles them into K8s Secrets on each cluster.
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "alloy_token" {
  count = local.observability_enabled ? 1 : 0

  name        = "${local.ssm_path_prefix}/alloy-token"
  description = "Grafana Cloud Alloy remote_write token. Provisioned by terraform/environments/staging/observability/; consumed by ExternalSecret → K8s Secret `alloy-token` in ns `monitoring`, mounted as env GRAFANA_CLOUD_TOKEN by the Alloy Deployment (staging/platform)."
  type        = "SecureString"
  key_id      = data.aws_kms_alias.secrets[0].target_key_arn
  value       = grafana_cloud_access_policy_token.alloy[0].token

  tags = merge(local.tags, {
    Name = "grafana-cloud-alloy-token"
  })
}

resource "aws_ssm_parameter" "grafana_operator_token" {
  count = local.observability_enabled ? 1 : 0

  name        = "${local.ssm_path_prefix}/grafana-operator-token"
  description = "Grafana Cloud stack Service Account token (Admin role). Provisioned by terraform/environments/staging/observability/; consumed by ExternalSecret → K8s Secret `grafana-operator-token` in ns `observability`, referenced by the Grafana CRD's spec.external.apiKey."
  type        = "SecureString"
  key_id      = data.aws_kms_alias.secrets[0].target_key_arn
  value       = grafana_cloud_stack_service_account_token.grafana_operator[0].key

  tags = merge(local.tags, {
    Name = "grafana-cloud-grafana-operator-token"
  })
}

# -----------------------------------------------------------------------------
# team-webhooks-slack-aegis — placeholder for aegis-core (ldz #126 CP1)
# -----------------------------------------------------------------------------
# Fulfills the pre-provisioning contract agreed in ldz #126: the SSM PS key
# `/aegis/staging/grafana-cloud/team-webhooks-slack-aegis` exists with a
# valid (if placeholder) value by the time aegis-core's ArgoCD app starts
# reconciling GrafanaContactPoint. Without this key, grafana-operator's
# Secret-not-found loop stalls silently — exactly the failure mode #126 was
# opened to prevent.
#
# Operator fills the real Slack webhook URL via AWS CLI:
#
#   aws ssm put-parameter \
#     --region eu-central-1 \
#     --name /aegis/staging/grafana-cloud/team-webhooks-slack-aegis \
#     --type SecureString --key-id alias/aegis-staging-secrets \
#     --value 'https://hooks.slack.com/services/T.../B.../...' \
#     --overwrite
#
# lifecycle.ignore_changes = [value] prevents subsequent `terraform apply`
# from clobbering the operator-supplied value back to the placeholder.
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "team_webhooks_slack_aegis" {
  count = local.observability_enabled ? 1 : 0

  name        = "${local.ssm_path_prefix}/team-webhooks-slack-aegis"
  description = "Slack webhook URL for aegis team notifications. Operator-managed value; Terraform creates the SecureString shell only. Consumed by ExternalSecret → K8s Secret `team-webhooks` (key `slack-aegis`) in ns `aegis`, referenced by aegis-core's GrafanaContactPoint CRD (ldz #126)."
  type        = "SecureString"
  key_id      = data.aws_kms_alias.secrets[0].target_key_arn
  # Placeholder value. The real webhook URL is put-parameter'd by the
  # operator out-of-band; Terraform never sees or touches it after create.
  value = "placeholder-operator-must-overwrite"

  tags = merge(local.tags, {
    Name = "grafana-cloud-team-webhooks-slack-aegis"
  })

  lifecycle {
    ignore_changes = [value]
  }
}
