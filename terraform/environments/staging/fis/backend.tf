terraform {
  backend "s3" {
    bucket       = "aegis-terraform-state-345895787808"
    key          = "staging/fis/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
    encrypt      = true
  }
}
