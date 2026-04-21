# -----------------------------------------------------------------------------
# Outputs — operator-facing only (no downstream Terraform consumers)
# -----------------------------------------------------------------------------
# Observability is a leaf layer. Nothing reads its state. Outputs exist for
# human use: where to log in, where the secrets live, how to rotate. No
# sensitive values — tokens are in SSM PS, retrieved via AWS CLI per
# Runbook 006.
# -----------------------------------------------------------------------------

output "grafana_stack_url" {
  description = "Browser-facing URL of the Grafana Cloud stack. Human login via Google OAuth (Runbook 006 Part 3). Null when observability_enabled=false."
  value       = local.observability_enabled ? "https://${local.grafana_cloud.org_slug}.grafana.net" : null
}

output "grafana_stack_region_slug" {
  description = "Grafana Cloud stack region slug (e.g. prod-eu-west-3). Read-only attribute from the stack data source — useful when rotating tokens or adding a secondary Access Policy."
  value       = try(data.grafana_cloud_stack.this[0].region_slug, null)
}

output "ssm_paths" {
  description = "SSM PS parameter paths for the three downstream secrets. Values are NOT output (secure by location, not by masking). Retrieve with: aws ssm get-parameter --name <path> --with-decryption."
  value = local.observability_enabled ? {
    bootstrap_token           = "${local.ssm_path_prefix}/bootstrap-token"
    alloy_token               = "${local.ssm_path_prefix}/alloy-token"
    grafana_operator_token    = "${local.ssm_path_prefix}/grafana-operator-token"
    team_webhooks_slack_aegis = "${local.ssm_path_prefix}/team-webhooks-slack-aegis"
  } : null
}

output "grafana_admin_login_hint" {
  description = <<-EOT
    How to log in to the Grafana Cloud stack as a human admin:

      1. Open the URL from `grafana_stack_url` output
      2. Click "Sign in with Google"
      3. Use the Gmail account invited during Runbook 006 Part 3 (Admin role)

    Break-glass service account tokens live in SSM PS — see `ssm_paths` output.
    Free tier does NOT support SAML; upgrade to Grafana Cloud Pro or migrate
    to AMG when that becomes a requirement (ADR-022 §Known limitations).
  EOT
  value       = "See description above."
}

output "observability_enabled" {
  description = "Whether the observability layer provisioned any resources (true when config.grafana_cloud is present, false otherwise)."
  value       = local.observability_enabled
}
