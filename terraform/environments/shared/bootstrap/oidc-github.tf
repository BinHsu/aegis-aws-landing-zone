# -----------------------------------------------------------------------------
# GitHub OIDC Federation — Zero Static Credentials
# -----------------------------------------------------------------------------
# Allows GitHub Actions to authenticate to this account via OIDC.
# No IAM access keys are created or stored anywhere.
# See: https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services
# -----------------------------------------------------------------------------

locals {
  github_org       = local.config.github.org
  github_infra_repo = local.config.github.infra_repo
  github_oidc_url  = "https://token.actions.githubusercontent.com"

  # OIDC subject claims allowed to assume the CI role
  # Format: repo:<org>/<repo>:<context>
  # Using wildcard to allow both PR plans and main-branch applies
  github_oidc_subjects = [
    "repo:${local.github_org}/${local.github_infra_repo}:ref:refs/heads/main",
    "repo:${local.github_org}/${local.github_infra_repo}:pull_request",
  ]
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = local.github_oidc_url
  client_id_list  = ["sts.amazonaws.com"]

  # AWS handles GitHub OIDC certificate validation automatically.
  # This thumbprint is required by the API but not used for verification
  # when the OIDC provider is a known provider (GitHub, Google, etc.).
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# -----------------------------------------------------------------------------
# CI/CD IAM Role — assumed by GitHub Actions via OIDC
# -----------------------------------------------------------------------------
# This role is used by GitHub Actions workflows for terraform plan/apply
# against the shared account (state bucket, AFT, shared resources).
#
# Permissions: AdministratorAccess (lab project, single operator).
# Production environments should scope down to least-privilege.
# The OIDC condition is the primary access control — only the specific
# GitHub repo can assume this role.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "github_ci" {
  name = "github-actions-terraform"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(local.github_oidc_url, "https://", "")}:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "${replace(local.github_oidc_url, "https://", "")}:sub" = local.github_oidc_subjects
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_ci" {
  role       = aws_iam_role.github_ci.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
