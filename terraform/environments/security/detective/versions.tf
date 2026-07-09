terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.40"
    }
    # `external` backs the read-only CT Config-aggregator assertion in
    # ct-config-aggregator-check.tf (no native data source exists for
    # aws_config_configuration_aggregator as of provider 6.x).
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}
