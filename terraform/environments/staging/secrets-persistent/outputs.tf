# -----------------------------------------------------------------------------
# Outputs — operator inspection only (ADR-028)
# -----------------------------------------------------------------------------
# This layer has no downstream `terraform_remote_state` consumer. Other
# layers read SSM PS values directly via `data "aws_ssm_parameter"` or
# via ESO ClusterSecretStore at runtime — both bypass Terraform state
# entirely and depend only on the SSM path strings, which are the
# canonical interface (ADR-028 §SSM path prefix unchanged).
#
# Outputs below exist for `terraform output` inspection during
# debugging: confirming which paths this layer claims to own, and
# whether the per-credential gates resolved to enabled or disabled.
# -----------------------------------------------------------------------------

output "grafana_cloud_enabled" {
  description = "Whether the Grafana Cloud SSM PS shells (bootstrap-token, team-webhooks-slack-aegis) were provisioned. Mirrors the gate condition `config.grafana_cloud != null`."
  value       = local.grafana_cloud_enabled
}

output "qdrant_enabled" {
  description = "Whether the Qdrant Cloud SSM PS shells (cluster-url, api-key) were provisioned. Mirrors the gate condition `config.qdrant_cloud.enabled`."
  value       = local.qdrant_enabled
}

output "ssm_paths" {
  description = "Map of SSM PS paths owned by this layer. Empty entries indicate a disabled gate. Useful for cross-checking against staging/observability data sources and aegis-core ExternalSecret remoteRef.key strings."
  value = {
    grafana_cloud_bootstrap_token     = local.grafana_cloud_enabled ? "${local.grafana_cloud_ssm_path_prefix}/bootstrap-token" : null
    grafana_cloud_team_webhooks_slack = local.grafana_cloud_enabled ? "${local.grafana_cloud_ssm_path_prefix}/team-webhooks-slack-aegis" : null
    qdrant_cloud_cluster_url          = local.qdrant_enabled ? "${local.qdrant_ssm_path_prefix}/cluster-url" : null
    qdrant_cloud_api_key              = local.qdrant_enabled ? "${local.qdrant_ssm_path_prefix}/api-key" : null
  }
}
