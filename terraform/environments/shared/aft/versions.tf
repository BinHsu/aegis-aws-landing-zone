terraform {
  required_version = ">= 1.10.0"

  # AFT module >= 1.12 requires AWS provider v6+.
  # This environment uses a newer provider than other environments because
  # the AFT module drives the constraint. This is acceptable: each Terraservices
  # layer has its own lock file and state, so provider versions are independent.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
