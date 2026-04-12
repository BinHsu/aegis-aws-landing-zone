# -----------------------------------------------------------------------------
# Terraform Backend — ADR-003
# -----------------------------------------------------------------------------
# State lives in aegis-shared account's S3 bucket with native locking.
# Cross-account access is granted by the bucket policy (aws:PrincipalOrgID).
# -----------------------------------------------------------------------------

terraform {
  backend "s3" {
    bucket       = "aegis-terraform-state-345895787808"
    key          = "management/bootstrap/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
  }
}
