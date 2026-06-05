# -----------------------------------------------------------------------------
# GitHub OIDC Federation — deployment account CI access
# -----------------------------------------------------------------------------
# Provides the OIDC provider that the gh-tf-* CI roles federate against. Each
# role's trust + permission policy lives in its own .tf file (oidc-github-*-
# role.tf). The two landing-zone CI roles are `gh-tf-plan` and
# `gh-tf-apply-baseline` — they bootstrap THIS layer (alias, OIDC provider,
# the gh-tf-* / aegis-emergency-* roles).
#
# The shared release-artifact registry (ECR) itself, and the platform-aws CI
# apply role that provisions it (`gh-tf-apply-deployment`) plus the scoped
# workload OIDC push role (`ecr:PutImage`), are NOT created here — they live
# in the aegis-platform-aws sibling PR (this repo owns the account fabric +
# the OIDC trust anchor only, per ADR-017). Both downstream roles match the
# org SCP `gh-tf-*` carve-out, so no SCP change is required (ADR-018).
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
