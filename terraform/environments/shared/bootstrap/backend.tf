# -----------------------------------------------------------------------------
# Terraform Backend — Chicken-and-Egg (ADR-003, ADR-010)
# -----------------------------------------------------------------------------
# This environment creates the S3 bucket that holds all Terraform state.
# It starts with a local backend because the bucket does not exist yet.
#
# After the first successful apply:
#
# 1. Uncomment the S3 backend block below.
# 2. Comment out or remove the local backend block.
# 3. Run: terraform init -migrate-state
# 4. Confirm the migration when prompted.
# 5. Delete the local terraform.tfstate file.
#
# After migration, the state for this environment lives at:
#   s3://<bucket>/shared/bootstrap/terraform.tfstate
# -----------------------------------------------------------------------------

terraform {
  backend "s3" {
    bucket       = "aegis-terraform-state-345895787808"
    key          = "shared/bootstrap/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
  }
}
