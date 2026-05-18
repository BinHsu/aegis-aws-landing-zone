# -----------------------------------------------------------------------------
# Input variables — ADR-032 external orchestration
# -----------------------------------------------------------------------------

variable "region" {
  description = <<-EOT
    AWS region this apply targets. Injected by the orchestrator (the root
    Makefile or the CI matrix) as TF_VAR_region. Must be one of
    eks.staging.regions[].region in config/landing-zone.yaml — the
    `region_is_configured` check in config.tf enforces this at plan time.
  EOT
  type        = string
}
