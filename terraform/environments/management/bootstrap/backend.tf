# -----------------------------------------------------------------------------
# Terraform Backend
# -----------------------------------------------------------------------------
# Phase 1: local backend until aegis-shared account + state bucket exist.
# Phase 2: migrate to S3 with native locking per ADR-003:
#
#   terraform {
#     backend "s3" {
#       bucket       = "aegis-terraform-state"
#       key          = "management/bootstrap/terraform.tfstate"
#       region       = "eu-central-1"
#       use_lockfile = true
#     }
#   }
#
# Migration command: terraform init -migrate-state
# -----------------------------------------------------------------------------

terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
