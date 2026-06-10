# -----------------------------------------------------------------------------
# GitHub OIDC Federation — staging account CI access
# -----------------------------------------------------------------------------
# Provides the OIDC provider that the gh-tf-* CI roles federate against. Each
# role's trust + permission policy lives in its own .tf file (oidc-github-*-
# role.tf). The two CI roles are `gh-tf-plan` and `gh-tf-apply-baseline`.
#
# Legacy `github-actions-terraform` (Admin) was removed by ADR-014 PR-7
# cleanup; see incidents.md §Incident 12 for the rollout narrative.
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

  lifecycle {
    # Fail closed (ADR-019). The immutable repository_id StringEquals claim is
    # the ONLY repo binding in the gh-tf-* trust policies — the StringLike sub
    # claim wildcards the repo name (`repo:<org>/*`) for rename-proofing.
    # Without infra_repo_id, ANY repo under the GitHub owner could mint a
    # main-branch token and assume the CI roles. Refuse to create that trust.
    precondition {
      condition     = local.github_infra_repo_id != null
      error_message = "github.infra_repo_id is unset in config/landing-zone.yaml. Set it — get the numeric id via: gh api repos/<owner>/<repo> --jq .id — the OIDC trust will not be created owner-wide (ADR-019)."
    }
  }
}
