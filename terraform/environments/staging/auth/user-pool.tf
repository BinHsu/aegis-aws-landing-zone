# -----------------------------------------------------------------------------
# Cognito User Pool — cloud-mode auth for aegis (ADR-026)
# -----------------------------------------------------------------------------
# This is the core resource. Recreating the pool destroys every
# registered user — Cognito does not export password hashes in any
# re-importable format. `prevent_destroy = true` is the operational
# guardrail against accidental `terraform destroy`.
#
# Immutable-attribute caveat: adding or removing a schema entry after
# the pool is created REQUIRES recreate. aegis-core's Q4 custom
# attribute `custom:tenant_id` (mutable=false) is declared below at
# creation time; changing its shape later means destroying the pool.
# This is a deliberate choice from ADR-026 — tenant claims should not be
# mutable after user creation.
#
# Username attribute choice: `username_attributes = ["email"]` means
# users log in with their email address, not a separate username field.
# Simpler UX for lab scale; aligns with how most SaaS auth flows are
# shaped today.
#
# Self-signup disabled (`allow_admin_create_user_only = true`) per
# ADR-026 §Decision. The operator manually invites users via
# `admin-create-user` — see Runbook 008 Part 2.
# -----------------------------------------------------------------------------

resource "aws_cognito_user_pool" "this" {
  count = local.auth_enabled ? 1 : 0

  name = "aegis-staging"

  # Users log in with their email address; Cognito auto-generates an
  # internal username for the record (a UUID, shown as `sub` in tokens).
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # Password policy — driven from config; lab default is NIST-aligned.
  password_policy {
    minimum_length                   = local.password_policy.minimum_length
    require_lowercase                = local.password_policy.require_lowercase
    require_uppercase                = local.password_policy.require_uppercase
    require_numbers                  = local.password_policy.require_numbers
    require_symbols                  = local.password_policy.require_symbols
    temporary_password_validity_days = 7
  }

  # ---------------------------------------------------------------------------
  # Q4 custom attribute — `custom:tenant_id` (ADR-026 §Decision)
  # ---------------------------------------------------------------------------
  # Declared here at pool creation time. Cognito auto-prefixes the name
  # with `custom:` — we set `name = "tenant_id"` and consumers read
  # `custom:tenant_id` from ID tokens.
  #
  # mutable = false: operator-set at user creation via
  # `admin-create-user --user-attributes Name=custom:tenant_id,Value=<tenant>`.
  # Not changeable after creation (except by deleting + recreating the
  # user). This is the security posture aegis-core's gateway relies on.
  #
  # String length 1..256 — adequate for UUID-shaped tenant IDs and for
  # the short-token tenant identifiers aegis-core has been designing.
  # ---------------------------------------------------------------------------
  schema {
    name                = "tenant_id"
    attribute_data_type = "String"
    mutable             = false
    required            = false

    string_attribute_constraints {
      min_length = 1
      max_length = 256
    }
  }

  # Self-signup disabled. Only admins create users — see Runbook 008.
  admin_create_user_config {
    allow_admin_create_user_only = true

    invite_message_template {
      email_subject = "Welcome to aegis"
      email_message = "Your aegis account has been created. Username: {username}. Temporary password: {####}. Sign in at the aegis portal and change your password on first login."
      sms_message   = "Your aegis username is {username} and temporary password is {####}."
    }
  }

  # Account recovery — email only (lab is email-verified, no phone).
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # MFA posture — driven from config. Lab default OFF.
  mfa_configuration = local.mfa_configuration

  # Advanced security mode OFF for lab. Enabling `AUDIT` or `ENFORCED`
  # costs an extra $0.05 per MAU which still fits lab scale but adds
  # noise to the demo narrative — defer until the security-angle
  # portfolio ask justifies it.
  user_pool_add_ons {
    advanced_security_mode = "OFF"
  }

  # Deletion protection — Cognito's first-class safety net, orthogonal
  # to Terraform's prevent_destroy. Belt + suspenders: even if a future
  # PR drops `prevent_destroy`, deletion_protection still forces an
  # explicit console / CLI opt-out before the pool can be deleted.
  deletion_protection = "ACTIVE"

  tags = merge(local.tags, {
    Name = "aegis-staging"
  })

  lifecycle {
    prevent_destroy = true
  }
}
