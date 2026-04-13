terraform {
  backend "s3" {
    bucket       = "aegis-terraform-state-345895787808"
    key          = "shared/ipam/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
  }
}
