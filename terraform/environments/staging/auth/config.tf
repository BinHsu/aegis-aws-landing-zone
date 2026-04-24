# -----------------------------------------------------------------------------
# Configuration Contract — ADR-004, ADR-026
# -----------------------------------------------------------------------------
# Peer Terraservice layer for the Cognito User Pool that backs cloud-mode
# auth for aegis-core's SPA and gateway (ADR-026).
#
# Gate: presence of config.cognito. Without the block, the whole layer
# plans to zero resources — forkers can apply a fresh staging without
# enabling auth, then enable it later by adding the `cognito:` block and
# re-applying. Mirrors staging/observability/config.tf observability_enabled
# gate.
#
# Lifecycle posture (ADR-026 §Decision):
#   - Baseline-tier: auto-apply on merge to main, never torn down by
#     terraform-teardown-workload.yml.
#   - User Pool + SSM parameters carry `lifecycle.prevent_destroy = true`.
#     Teardown is explicit via Runbook 008 §Permanent teardown.
#   - Rolling the User Pool destroys every registered user — Cognito does
#     not export password hashes in an importable format.
#
# This layer is primary-only (ADR-026 §Decision). No slot pattern, no
# K=2 guard — Cognito's resources are global per pool. If the top-level
# config declares eks.staging.regions with length > 2 it is still a
# repo-wide governance breach and the sibling layers will refuse to plan;
# this layer does not need its own guard because it reads zero
# slot-dependent state.
# -----------------------------------------------------------------------------

locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))

  account_id     = local.config.accounts.staging.id
  primary_region = [for r in local.config.regions : r.name if r.role == "primary"][0]

  # Cognito block — gate for the whole layer.
  cognito      = try(local.config.cognito, null)
  auth_enabled = local.cognito != null

  # SSM PS path prefix — ADR-026 §Decision. All Cognito-related identifiers
  # live under this prefix so the ESO ClusterSecretStore IAM policy can
  # scope to the whole family with a single wildcard (which it already
  # does for /aegis/staging/* — see staging/platform ESO IRSA).
  ssm_path_prefix = "/aegis/staging/cognito"

  # Callback + logout URL lists. Strawman defaults per aegis-core #76
  # (2026-04-23) — SPA's OAuth redirect target + post-logout landing URL.
  # Defensive fallback: Cognito requires at least one entry in each list;
  # an empty list in config would make the apply fail with an unhelpful
  # error. Keep the strawman default so the layer always plans cleanly.
  callback_urls = try(
    length(local.cognito.callback_urls) > 0 ? local.cognito.callback_urls : null,
    null,
  ) != null ? local.cognito.callback_urls : ["https://aegis-app.staging.binhsu.org/auth/callback"]

  logout_urls = try(
    length(local.cognito.logout_urls) > 0 ? local.cognito.logout_urls : null,
    null,
  ) != null ? local.cognito.logout_urls : ["https://aegis-app.staging.binhsu.org/"]

  # Domain prefix — Cognito-provided hosted UI
  # (<prefix>.auth.<region>.amazoncognito.com). Fixed to "aegis-staging"
  # for this lab; forkers override via config.
  domain_prefix = try(local.cognito.domain_prefix, "aegis-staging")

  # Password policy — lab defaults roughly mirror NIST SP 800-63B
  # minimum-12-chars guidance.
  password_policy = try(local.cognito.password_policy, {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  })

  # MFA posture. Lab default OFF (self-operator only); forkers running
  # demo scenarios may toggle to OPTIONAL without a schema change.
  # ON is not recommended for MVP — Cognito ON requires an SMS / TOTP
  # factor configured per user and hard-fails login if absent.
  mfa_configuration = try(local.cognito.mfa_configuration, "OFF")

  tags = merge(local.config.tags, {
    Environment = "staging"
    Component   = "auth"
  })

  # Per-cluster details read from staging/platform's per-slot clusters map.
  # Auth targets the primary cluster only (see providers.tf rationale).
  clusters = try(data.terraform_remote_state.staging_platform.outputs.clusters, {})
}

# -----------------------------------------------------------------------------
# Cross-field invariants — mirror of staging/observability
# -----------------------------------------------------------------------------

check "exactly_one_primary_region" {
  assert {
    condition     = length([for r in local.config.regions : r if r.role == "primary"]) == 1
    error_message = "config/landing-zone.yaml regions[] must have exactly one entry with role: primary."
  }
}

check "mfa_configuration_valid" {
  assert {
    condition     = contains(["OFF", "OPTIONAL", "ON"], local.mfa_configuration)
    error_message = "cognito.mfa_configuration must be one of OFF, OPTIONAL, ON — got '${local.mfa_configuration}'."
  }
}

# -----------------------------------------------------------------------------
# Cross-layer state read — consume platform's clusters map
# -----------------------------------------------------------------------------
# Auth is a peer layer that depends on staging/platform (EKS cluster must
# exist for the kubectl provider to reach the primary apiserver) AND on
# staging/workloads (the `aegis` namespace must exist for the
# cognito-config ExternalSecret to land in that namespace). Apply
# ordering for the ExternalSecret is enforced operationally: on a cold
# cycle where workloads has not been applied yet, the kubectl_manifest
# apply fails with "namespaces \"aegis\" not found" and the operator
# re-dispatches baseline after workloads. The AWS-side resources
# (user pool, app client, domain, SSM params) apply cleanly regardless.
# -----------------------------------------------------------------------------

data "terraform_remote_state" "staging_platform" {
  backend = "s3"
  config = {
    bucket = "${local.config.organization.name}-terraform-state-${local.config.accounts.shared.id}"
    key    = "staging/platform/terraform.tfstate"
    region = local.primary_region
  }
}

data "aws_caller_identity" "current" {}

check "expected_account" {
  assert {
    condition     = data.aws_caller_identity.current.account_id == local.account_id
    error_message = "Running against the wrong AWS account (${data.aws_caller_identity.current.account_id}) — staging/auth must be applied with credentials for ${local.account_id} (aegis-staging)."
  }
}

check "platform_layer_applied" {
  assert {
    condition = (
      !local.auth_enabled
      || (
        data.terraform_remote_state.staging_platform.outputs != null
        && try(contains(keys(data.terraform_remote_state.staging_platform.outputs.clusters), "primary"), false)
      )
    )
    error_message = "staging/platform has not been applied or its clusters map is missing the primary slot. Apply staging/platform before staging/auth (gh workflow run terraform-apply-workload.yml -f env=staging)."
  }
}

# -----------------------------------------------------------------------------
# SSM PS SecureString encryption key — contract with staging/bootstrap
# -----------------------------------------------------------------------------
# Alias `alias/aegis-staging-secrets` is owned by
# staging/bootstrap/kms-secrets.tf. Looked up by alias to avoid chaining
# bootstrap state into this layer. The check below fires a readable
# error if a forker attempts auth before bootstrap.
# -----------------------------------------------------------------------------

data "aws_kms_alias" "secrets" {
  count = local.auth_enabled ? 1 : 0

  name = "alias/aegis-staging-secrets"
}

check "secrets_kms_key_exists" {
  assert {
    condition = (
      !local.auth_enabled
      || try(data.aws_kms_alias.secrets[0].target_key_arn, "") != ""
    )
    error_message = "config.cognito is set but KMS alias 'alias/aegis-staging-secrets' is missing. Apply staging/bootstrap first (baseline layer, auto-applied on PR merge — see staging/bootstrap/kms-secrets.tf)."
  }
}

# -----------------------------------------------------------------------------
# GitHub OIDC provider — lookup from staging/bootstrap
# -----------------------------------------------------------------------------
# The aegis-core integration IAM role assumes via the GitHub OIDC
# provider created in staging/bootstrap/oidc-github.tf. Looked up by URL
# so we do not chain bootstrap state into this layer's inputs.
# -----------------------------------------------------------------------------

data "aws_iam_openid_connect_provider" "github" {
  count = local.auth_enabled ? 1 : 0

  url = "https://token.actions.githubusercontent.com"
}
