# -----------------------------------------------------------------------------
# Account Factory for Terraform (AFT) — Path B (ADR-011)
# -----------------------------------------------------------------------------
# This environment deploys the AFT infrastructure into aegis-shared.
# It is NOT deployed by default. Deploy only when the operator decides to
# activate Path B per the decision tree in ADR-011.
#
# Before deploying:
#   1. Review the AFT module version — check the Terraform Registry for the
#      latest stable release of aws-ia/control_tower_account_factory/aws.
#   2. Create a GitHub CodeStar connection in the AWS console (if using GitHub
#      as VCS) or use the default CodeCommit repositories.
#   3. Create the four AFT companion repositories (or directories):
#      - aft-account-request
#      - aft-global-customizations
#      - aft-account-customizations
#      - aft-account-provisioning-customizations
#
# Ongoing cost: ~$10-15/month (CodePipeline, CodeBuild, Lambda, DynamoDB, S3)
#
# Reference: https://docs.aws.amazon.com/controltower/latest/userguide/aft-overview.html
# Module:    https://registry.terraform.io/modules/aws-ia/control_tower_account_factory/aws
# -----------------------------------------------------------------------------

module "aft" {
  source  = "aws-ia/control_tower_account_factory/aws"
  version = "~> 1.12"

  # Control Tower account IDs — read from config
  ct_management_account_id    = local.config.accounts.management.id
  log_archive_account_id      = local.config.accounts.logarchive.id
  audit_account_id            = local.config.accounts.security.id
  aft_management_account_id   = local.config.accounts.shared.id

  # Region configuration
  ct_home_region              = local.primary_region
  tf_backend_secondary_region = local.dr_region

  # VCS configuration — default: CodeCommit (AWS-hosted, zero additional setup)
  # To use GitHub instead, set:
  #   vcs_provider                                  = "github"
  #   account_request_repo_name                     = "BinHsu/aegis-aft-account-request"
  #   global_customizations_repo_name               = "BinHsu/aegis-aft-global-customizations"
  #   account_customizations_repo_name              = "BinHsu/aegis-aft-account-customizations"
  #   account_provisioning_customizations_repo_name = "BinHsu/aegis-aft-account-provisioning-customizations"
  # and create a CodeStar connection to GitHub in the AWS console.
  vcs_provider = "codecommit"

  # Terraform distribution — use the official HashiCorp distribution
  terraform_distribution = "oss"

  # Feature flags
  aft_feature_cloudtrail_data_events      = false  # Cost control: data events are expensive
  aft_feature_enterprise_support          = false  # Not applicable for lab accounts
  aft_feature_delete_default_vpcs_enabled = true   # Clean up default VPCs in all regions
}

check "config_account_ids_not_empty" {
  assert {
    condition = alltrue([
      local.config.accounts.management.id != "",
      local.config.accounts.security.id != "",
      local.config.accounts.logarchive.id != "",
      local.config.accounts.shared.id != "",
    ])
    error_message = "All four foundation account IDs must be populated in landing-zone.yaml before deploying AFT."
  }
}
