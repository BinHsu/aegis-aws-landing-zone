#!/usr/bin/env bash
# disable-member-detectors.sh — stop member-account GuardDuty billing after a
# detective-layer toggle-off (Epic #302; Bin's lifecycle decision on #305/#306).
#
# WHY THIS EXISTS: `detective_enabled = false` destroys only what Terraform
# owns — the delegated-admin detector, the org auto-enable configuration, and
# the Security Hub resources in the security account. The member-account
# detectors that `auto_enable_organization_members = "ALL"` auto-created are
# NOT in Terraform state and keep analyzing CloudTrail events (billing) until
# each one is deleted in its own account. This script does that sweep.
#
# RUN AS: a management-account admin (e.g. `aegis-management-admin` SSO
# profile). It assumes AWSControlTowerExecution in each member account —
# the delegated admin cannot delete member detectors, only the members can.
#
# ORDER: run AFTER the toggle-off apply. If auto-enable were still "ALL",
# GuardDuty would just re-enroll the accounts you clean up.
#
# SAFE BY DEFAULT: dry-run unless --execute is passed. Read-only calls only
# in dry-run mode.
#
# Usage:
#   ./disable-member-detectors.sh [--execute] [--region eu-central-1]

set -euo pipefail

REGION="eu-central-1"
EXECUTE=false
ROLE_NAME="AWSControlTowerExecution"

while [ $# -gt 0 ]; do
  case "$1" in
    --execute) EXECUTE=true ;;
    --region)
      shift
      REGION="$1"
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--execute] [--region <region>]" >&2
      exit 1
      ;;
  esac
  shift
done

mgmt_account="$(aws sts get-caller-identity --query Account --output text)"
echo "Caller account: ${mgmt_account} | region: ${REGION} | mode: $($EXECUTE && echo EXECUTE || echo DRY-RUN)"

accounts="$(aws organizations list-accounts \
  --query 'Accounts[?Status==`ACTIVE`].[Id,Name]' --output text)"

while IFS=$'\t' read -r account_id account_name; do
  [ -z "$account_id" ] && continue
  if [ "$account_id" = "$mgmt_account" ]; then
    # The management account is not governed by AWSControlTowerExecution;
    # its detector (if any) is handled with the caller's own credentials.
    creds_env=""
  else
    if ! creds="$(aws sts assume-role \
      --role-arn "arn:aws:iam::${account_id}:role/${ROLE_NAME}" \
      --role-session-name detective-teardown \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
      --output text 2>/dev/null)"; then
      echo "SKIP  ${account_id} (${account_name}): cannot assume ${ROLE_NAME}"
      continue
    fi
    creds_env="AWS_ACCESS_KEY_ID=$(echo "$creds" | cut -f1) AWS_SECRET_ACCESS_KEY=$(echo "$creds" | cut -f2) AWS_SESSION_TOKEN=$(echo "$creds" | cut -f3)"
  fi

  detector_id="$(env $creds_env aws guardduty list-detectors \
    --region "$REGION" --query 'DetectorIds[0]' --output text 2>/dev/null || true)"

  if [ -z "$detector_id" ] || [ "$detector_id" = "None" ]; then
    echo "OK    ${account_id} (${account_name}): no detector"
    continue
  fi

  if $EXECUTE; then
    env $creds_env aws guardduty delete-detector \
      --region "$REGION" --detector-id "$detector_id"
    echo "DONE  ${account_id} (${account_name}): deleted detector ${detector_id}"
  else
    echo "WOULD ${account_id} (${account_name}): delete detector ${detector_id}"
  fi
done <<< "$accounts"

echo "Sweep complete. Re-run with --execute to act." | { $EXECUTE && cat > /dev/null || cat; }
