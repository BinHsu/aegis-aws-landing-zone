# -----------------------------------------------------------------------------
# GitHub OIDC Federation — staging account CI access
# -----------------------------------------------------------------------------
# Provides the OIDC provider that the gh-tf-* CI roles federate against. Each
# role's trust + permission policy lives in its own .tf file (oidc-github-*-
# role.tf). After the ADR-033 account-fabric descope only `gh-tf-plan` and
# `gh-tf-apply-baseline` remain; the aegis-core CI roles were removed with the
# Platform-tier layers (ECR, Bazel cache) they served.
#
# Legacy `github-actions-terraform` (Admin) was removed by ADR-029 PR-7
# cleanup; see incidents.md §Incident 36 for the rollout narrative.
# -----------------------------------------------------------------------------

locals {
  github_org        = local.config.github.org
  github_infra_repo = local.config.github.infra_repo
  github_oidc_url   = "https://token.actions.githubusercontent.com"

  github_infra_repo_id = try(local.config.github.infra_repo_id, null)

  github_oidc_infra_repo_id_claim = local.github_infra_repo_id != null ? {
    "${replace(local.github_oidc_url, "https://", "")}:repository_id" = local.github_infra_repo_id
  } : {}
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = local.github_oidc_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
