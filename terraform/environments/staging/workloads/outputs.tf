# -----------------------------------------------------------------------------
# Outputs — per-cluster map, keyed by slot name
# -----------------------------------------------------------------------------
# Workloads is a leaf layer: no downstream Terraform consumer reads these
# outputs (they are operator-facing only). Per-slot map for namespace + IRSA
# ARN + GuardDuty detector.
#
# The prior `grafana_admin_password_{primary,slave_1}` outputs were removed
# with ADR-022 (PR-3) when kube-prometheus-stack was replaced by Grafana
# Cloud. Human auth is now Google OAuth via the GC portal, not a break-glass
# random password on an in-cluster Grafana.
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
