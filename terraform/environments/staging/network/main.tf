# staging/network — VPC, subnets, and Transit Gateway attachments for the
# staging account.
#
# This layer is intentionally empty until the network topology is designed
# (tracked in GitHub Issues). The environment file exists now so that the
# CI required-status-check `Plan staging/network` can report on every PR
# (the check is gated by path filter in the workflow — see
# .github/workflows/terraform-plan.yml).

data "aws_caller_identity" "current" {}
