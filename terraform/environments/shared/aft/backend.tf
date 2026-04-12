# -----------------------------------------------------------------------------
# Terraform Backend — ADR-003
# -----------------------------------------------------------------------------
# State lives in aegis-shared's S3 bucket alongside all other state files.
# This environment is NOT deployed by default (see ADR-011 Path B).
# Deploy only when the operator activates the AFT provisioning path.
# -----------------------------------------------------------------------------

terraform {
  backend "s3" {
    bucket       = "aegis-terraform-state-345895787808"
    key          = "shared/aft/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
  }
}
