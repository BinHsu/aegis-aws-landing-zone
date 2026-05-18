# -----------------------------------------------------------------------------
# Backend — partial configuration (ADR-032)
# -----------------------------------------------------------------------------
# Applied once per region with a region-scoped state key. bucket / key / region
# are supplied by the orchestrator at `terraform init` time:
#
#   terraform init -reconfigure \
#     -backend-config="bucket=<org>-terraform-state-<shared-account-id>" \
#     -backend-config="key=staging/<region>/workloads/terraform.tfstate" \
#     -backend-config="region=<primary-region>"
#
# scripts/configure-backends.sh skips this layer (partial config, no literals).
# -----------------------------------------------------------------------------

terraform {
  backend "s3" {
    use_lockfile = true
  }
}
