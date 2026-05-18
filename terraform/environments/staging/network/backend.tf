# -----------------------------------------------------------------------------
# Backend — partial configuration (ADR-032)
# -----------------------------------------------------------------------------
# This layer is applied once per region with a region-scoped state key. The
# bucket / key / region are NOT literals here — they are supplied by the
# orchestrator at `terraform init` time:
#
#   terraform init -reconfigure \
#     -backend-config="bucket=<org>-terraform-state-<shared-account-id>" \
#     -backend-config="key=staging/<region>/network/terraform.tfstate" \
#     -backend-config="region=<primary-region>"
#
# The root Makefile and the CI workflows do this. `scripts/configure-backends.sh`
# intentionally skips this layer (it only templates full-literal backends).
# -----------------------------------------------------------------------------

terraform {
  backend "s3" {
    use_lockfile = true
  }
}
