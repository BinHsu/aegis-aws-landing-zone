# -----------------------------------------------------------------------------
# Providers — AWS-only (ADR-028 §Decision)
# -----------------------------------------------------------------------------
# This layer owns SSM PS resource shells for SaaS credentials. No K8s
# providers — ExternalSecret CRDs that consume these parameters live in
# staging/observability/, where the kubectl provider is already wired
# against the cluster. Splitting the K8s side here would duplicate that
# machinery for no benefit (ADR-028 §Decision §ExternalSecret CRDs stay
# in observability).
# -----------------------------------------------------------------------------

provider "aws" {
  region = local.primary_region

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [local.account_id]
}
