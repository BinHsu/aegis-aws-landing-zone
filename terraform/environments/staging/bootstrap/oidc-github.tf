# -----------------------------------------------------------------------------
# GitHub OIDC Federation — staging account CI access
# -----------------------------------------------------------------------------
# Provides the OIDC provider that all gh-tf-* roles + the four
# github-actions-aegis-core-* roles federate against. Each role's trust policy
# + permission policy lives in its own .tf file (see oidc-github-*-role.tf
# and oidc-aegis-core.tf).
#
# `github_app_repo` local stays — used by the aegis-core CI roles below.
# Legacy `github-actions-terraform` (Admin) was removed by ADR-029 PR-7
# cleanup; see incidents.md §Incident 36 for the rollout narrative.
# -----------------------------------------------------------------------------

locals {
  github_org        = local.config.github.org
  github_infra_repo = local.config.github.infra_repo
  github_oidc_url   = "https://token.actions.githubusercontent.com"

  github_app_repo = local.config.github.app_repo

  github_infra_repo_id = try(local.config.github.infra_repo_id, null)
  github_app_repo_id   = try(local.config.github.app_repo_id, null)

  github_oidc_infra_repo_id_claim = local.github_infra_repo_id != null ? {
    "${replace(local.github_oidc_url, "https://", "")}:repository_id" = local.github_infra_repo_id
  } : {}
  github_oidc_app_repo_id_claim = local.github_app_repo_id != null ? {
    "${replace(local.github_oidc_url, "https://", "")}:repository_id" = local.github_app_repo_id
  } : {}
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = local.github_oidc_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
