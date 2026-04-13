# -----------------------------------------------------------------------------
# GitHub OIDC Federation — staging account CI access
# -----------------------------------------------------------------------------
# Same pattern as management/bootstrap and shared/bootstrap. Allows GitHub
# Actions to deploy staging resources (network, platform, workloads layers)
# without static credentials.
# -----------------------------------------------------------------------------

locals {
  github_org        = local.config.github.org
  github_infra_repo = local.config.github.infra_repo
  github_oidc_url   = "https://token.actions.githubusercontent.com"

  github_oidc_subjects = [
    "repo:${local.github_org}/${local.github_infra_repo}:ref:refs/heads/main",
    "repo:${local.github_org}/${local.github_infra_repo}:pull_request",
  ]
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = local.github_oidc_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

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

# Staging CI role permissions are AdministratorAccess for lab simplicity.
# Production should scope down per Terraservices layer (network, platform,
# workloads) using least-privilege custom policies.
resource "aws_iam_role_policy_attachment" "github_ci" {
  role       = aws_iam_role.github_ci.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
