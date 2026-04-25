# -----------------------------------------------------------------------------
# Resource adoption via Terraform 1.5+ import { } block (ADR-028)
# -----------------------------------------------------------------------------
# Only one resource needs adoption on this PR's first apply: the
# bootstrap-token SSM PS that has lived in AWS as an operator-only
# resource since Runbook 006 §Part 2 (executed 2026-04-22). Pre-ADR-028,
# it had no Terraform shell — only a `data "aws_ssm_parameter"` lookup
# in staging/observability/config.tf. ADR-028 brings it under TF
# management; the import block is how that adoption happens declaratively
# in CI without operator-side `terraform import` ceremony.
#
# The for_each gate matches the resource's count gate. When
# grafana_cloud is disabled, both resolve to zero instances and the
# import is skipped.
#
# Idempotency: after first apply adopts the resource into state,
# subsequent plans see it already managed and the import block is a
# no-op (Terraform 1.5+ contract). The block can stay indefinitely or
# be removed in a follow-up cleanup PR; both are correct.
#
# Forker first-apply prerequisite: Runbook 006 §Part 2 must execute
# before this layer's first apply (the operator must `put-parameter`
# the bootstrap-token from the Grafana Cloud portal). Without the
# pre-existing AWS parameter, this import block fails. No new constraint
# vs. pre-ADR-028 — the bootstrap-token has always required
# pre-apply provisioning.
#
# Why no import block for the other three SSM PS in this layer:
#   - qdrant-cluster-url + qdrant-api-key: destroyed in Incident 33's
#     teardown. AWS-side resource does not exist; first apply creates
#     the placeholder shell, operator put-parameters real values per
#     Runbook 007 §Part 2/3.
#   - team-webhooks-slack-aegis: also destroyed in Incident 33's
#     teardown. Held only a placeholder string; first apply re-creates
#     the placeholder, operator put-parameters real value if and when
#     Slack alerting is wired (Runbook 006 §Part 4).
# -----------------------------------------------------------------------------

import {
  for_each = local.grafana_cloud_enabled ? toset(["bootstrap-token"]) : toset([])

  to = aws_ssm_parameter.bootstrap_token[0]
  id = "${local.grafana_cloud_ssm_path_prefix}/bootstrap-token"
}
