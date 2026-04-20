# -----------------------------------------------------------------------------
# Outputs — per-cluster map, keyed by slot name
# -----------------------------------------------------------------------------
# Workloads is a leaf layer: no downstream Terraform consumer reads these
# outputs (they are operator-facing only). No backward-compat flat outputs
# needed; switch directly to per-slot map for the namespace + IRSA ARN.
#
# Grafana admin password keeps two flat-per-slot outputs (one per slot)
# rather than a sensitive map, because the documented retrieval pattern
# is `terraform output -raw <name> | pbcopy` — flat outputs preserve that
# UX without needing jq to extract from a map. See README.md
# "Grafana admin password — break-glass retrieval".
# -----------------------------------------------------------------------------

output "workloads" {
  description = "Per-cluster workload details (namespace, engine IRSA role ARN, GuardDuty detector ID), keyed by slot name (primary, slave_1, ...)"
  value = merge(
    {
      primary = {
        namespace             = module.workloads_primary.namespace
        engine_irsa_role_arn  = module.workloads_primary.engine_irsa_role_arn
        guardduty_detector_id = module.workloads_primary.guardduty_detector_id
      }
    },
    length(module.workloads_slave_1) > 0 ? {
      slave_1 = {
        namespace             = module.workloads_slave_1[0].namespace
        engine_irsa_role_arn  = module.workloads_slave_1[0].engine_irsa_role_arn
        guardduty_detector_id = module.workloads_slave_1[0].guardduty_detector_id
      }
    } : {}
  )
}

# -----------------------------------------------------------------------------
# Grafana admin passwords — flat per slot, sensitive
# -----------------------------------------------------------------------------
# Two flat outputs (not a sensitive map) so the README-documented
# `terraform output -raw <name> | pbcopy` pattern stays a one-liner.
# Slave slot output is null when eks.staging.regions length is 1 — Terraform
# accepts null on sensitive outputs without errors.
# -----------------------------------------------------------------------------

output "grafana_admin_password_primary" {
  description = <<-EOT
    Grafana admin password for the PRIMARY cluster — BREAK-GLASS USE ONLY.

    Regular access should be via SSO (see docs/improvements/009-grafana-sso-integration.md
    for the roadmap; until it ships, this is also daily-use auth).

    Regenerates on every fresh `terraform apply` of the workloads layer.
    Retrieval without shell-history leak:

      cd terraform/environments/staging/workloads
      AWS_PROFILE=aegis-staging-admin terraform output -raw grafana_admin_password_primary | pbcopy

    See README.md "Grafana admin password — break-glass retrieval".
  EOT
  value       = module.workloads_primary.grafana_admin_password
  sensitive   = true
}

output "grafana_admin_password_slave_1" {
  description = <<-EOT
    Grafana admin password for the SLAVE_1 cluster — BREAK-GLASS USE ONLY.

    Null when eks.staging.regions is length 1 (no slave cluster deployed).
    Same retrieval pattern as primary; substitute the output name.
  EOT
  value       = try(module.workloads_slave_1[0].grafana_admin_password, null)
  sensitive   = true
}
