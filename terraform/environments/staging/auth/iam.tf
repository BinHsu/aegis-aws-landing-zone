# -----------------------------------------------------------------------------
# aegis-core integration IAM role — nightly CI (aegis-core #76 Q B)
# -----------------------------------------------------------------------------
# aegis-core's nightly integration workflow on `main` needs to exercise
# the Cognito user pool end-to-end: create a scratch user, mint a token,
# call the gateway, clean up. Rather than sharing a long-lived admin
# role, we provision a dedicated least-privilege role scoped to Cognito
# admin operations on THIS pool only.
#
# Same pattern as the existing `github-actions-aegis-core-ecr` and
# `github-actions-aegis-core-cache` roles in staging/bootstrap/oidc-
# aegis-core.tf — the aegis-core repo gets per-function least-privilege
# roles, never a catch-all admin role.
#
# Lifecycle: aegis-core has hardcoded this role's ARN in their nightly
# workflow. `prevent_destroy = true` on the role prevents an accidental
# Terraform destroy from breaking their CI overnight.
# -----------------------------------------------------------------------------

locals {
  # Wildcard variable keeps sub-claim construction readable and scopeable
  # if we ever widen access beyond `main` (e.g. a nightly branch).
  aegis_core_repo_ref = "repo:${local.config.github.org}/${local.config.github.app_repo}:ref:refs/heads/main"
}

resource "aws_iam_role" "aegis_core_cognito_integration" {
  count = local.auth_enabled ? 1 : 0

  name = "github-actions-aegis-core-cognito-integration"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = data.aws_iam_openid_connect_provider.github[0].arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.aegis_core_repo_ref
        }
      }
    }]
  })

  tags = merge(local.tags, {
    Name = "github-actions-aegis-core-cognito-integration"
  })

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Cognito admin policy — scoped to this pool only
# -----------------------------------------------------------------------------
# The nightly integration test:
#   1. AdminCreateUser      — invite a scratch user
#   2. AdminSetUserPassword — skip the reset flow
#   3. AdminInitiateAuth    — mint tokens without browser interaction
#   4. AdminGetUser         — idempotency check on repeat runs
#   5. AdminDeleteUser      — clean up at end of test
#
# All actions scoped to the `this` pool ARN — the role has zero
# authority on any other Cognito resource in the account.
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "aegis_core_cognito_integration" {
  count = local.auth_enabled ? 1 : 0

  name = "cognito-integration"
  role = aws_iam_role.aegis_core_cognito_integration[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "CognitoAdminOnThisPool"
      Effect = "Allow"
      Action = [
        "cognito-idp:AdminCreateUser",
        "cognito-idp:AdminSetUserPassword",
        "cognito-idp:AdminInitiateAuth",
        "cognito-idp:AdminGetUser",
        "cognito-idp:AdminDeleteUser",
      ]
      Resource = aws_cognito_user_pool.this[0].arn
    }]
  })
}

# -----------------------------------------------------------------------------
# SSM PS read policy — aegis-core reads outputs fresh each nightly run
# -----------------------------------------------------------------------------
# aegis-core #76 Q A-2: instead of hardcoding user-pool-id, app-client-id
# etc. into their CI, they read them from SSM PS on each run. Survives
# a pool recreate without an aegis-core code change.
# -----------------------------------------------------------------------------

resource "aws_iam_role_policy" "aegis_core_ssm_read" {
  count = local.auth_enabled ? 1 : 0

  name = "ssm-cognito-read"
  role = aws_iam_role.aegis_core_cognito_integration[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadCognitoParams"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
        ]
        Resource = "arn:aws:ssm:${local.primary_region}:${local.account_id}:parameter${local.ssm_path_prefix}/*"
      },
      {
        Sid      = "DecryptCognitoParams"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = data.aws_kms_alias.secrets[0].target_key_arn
      },
    ]
  })
}
