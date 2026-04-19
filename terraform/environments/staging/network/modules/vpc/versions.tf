terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.40"
      # `aws.this` is the per-region provider injected by the caller via
      # `providers = { aws.this = aws.primary }` or `{ aws.this = aws.slave_1 }`.
      # Role-based label per ADR-018 §3 amendment + CLAUDE.md "no hardcoded
      # regions in .tf" — the region value comes from config, the alias name
      # does not carry region semantics.
      configuration_aliases = [aws.this]
    }
  }
}
