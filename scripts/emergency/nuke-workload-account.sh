#!/usr/bin/env bash
# =============================================================================
# nuke-workload-account.sh — emergency cleanup for drifted workload account
# =============================================================================
# Wraps Gruntwork's cloud-nuke tool to destroy all resources in a workload
# account when Terraform state has drifted from reality (e.g., after a manual
# console change created resources Terraform does not know about).
#
# Can ONLY target workload accounts (staging, prod, sandbox). Explicitly
# refuses to target management, security, logarchive, or shared accounts —
# the damage there would be unrecoverable.
#
# Dry-run by default. Use --destroy to actually delete.
#
# Prerequisites:
#   - cloud-nuke installed (brew install cloud-nuke)
#   - AWS_PROFILE set and SSO session valid
#
# Usage:
#   ./scripts/emergency/nuke-workload-account.sh staging              # dry-run
#   ./scripts/emergency/nuke-workload-account.sh staging --destroy    # real
#
# See ADR-009.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV="${1:-}"
MODE="${2:---dry-run}"

# --- Validation ---

if [[ ! -t 0 ]]; then
  echo "ERROR: This script requires an interactive TTY." >&2
  exit 1
fi

if [[ -z "${ENV}" ]]; then
  echo "Usage: $0 <environment> [--dry-run|--destroy]" >&2
  echo "Default mode is --dry-run." >&2
  exit 1
fi

# Strict allowlist — workload environments only
case "${ENV}" in
  staging|prod|sandbox|sandbox-*)
    ;;
  management|security|logarchive|shared)
    echo "ERROR: '${ENV}' is a protected foundation account and cannot be nuked." >&2
    echo "This script intentionally refuses to damage foundation accounts." >&2
    exit 1
    ;;
  *)
    echo "ERROR: '${ENV}' is not a recognized workload environment." >&2
    echo "Allowed: staging, prod, sandbox, sandbox-*" >&2
    exit 1
    ;;
esac

case "${MODE}" in
  --dry-run|--destroy)
    ;;
  *)
    echo "ERROR: Unknown mode '${MODE}'. Use --dry-run or --destroy." >&2
    exit 1
    ;;
esac

if ! command -v cloud-nuke >/dev/null 2>&1; then
  echo "ERROR: cloud-nuke binary not found on PATH." >&2
  echo "Install with: brew install cloud-nuke" >&2
  exit 1
fi

# AWS_PROFILE must match target env
EXPECTED_PROFILE="aegis-${ENV}-admin"
if [[ "${AWS_PROFILE:-}" != "${EXPECTED_PROFILE}" ]]; then
  echo "ERROR: AWS_PROFILE is '${AWS_PROFILE:-unset}', expected '${EXPECTED_PROFILE}'." >&2
  exit 1
fi

# Verify caller identity
CONFIG_ACCT=$(python3 -c "
import yaml
c = yaml.safe_load(open('${REPO_ROOT}/config/landing-zone.yaml'))
print(c['accounts']['${ENV}']['id'])
")

ACTUAL_ACCT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  echo "ERROR: 'aws sts get-caller-identity' failed. Run 'aws sso login --sso-session aegis'." >&2
  exit 1
}

if [[ "${ACTUAL_ACCT}" != "${CONFIG_ACCT}" ]]; then
  echo "ERROR: Current AWS session is account ${ACTUAL_ACCT}, expected ${CONFIG_ACCT}." >&2
  exit 1
fi

# --- Confirmation ---

if [[ "${MODE}" == "--destroy" ]]; then
  echo ""
  echo "=============================================================================="
  echo "CLOUD-NUKE — ${ENV} (${CONFIG_ACCT})"
  echo "=============================================================================="
  echo ""
  echo "DESTRUCTIVE MODE: cloud-nuke will attempt to delete ALL resources"
  echo "in account ${CONFIG_ACCT} across the governed regions."
  echo ""
  echo "This bypasses Terraform state entirely. Any resources Terraform knows"
  echo "about will also be destroyed, and Terraform state will become invalid."
  echo ""
  echo "Type the account name '${ENV}' to confirm, anything else to abort:"
  read -r CONFIRM
  if [[ "${CONFIRM}" != "${ENV}" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

# --- Execute cloud-nuke ---

REGIONS="eu-central-1,eu-west-1"

if [[ "${MODE}" == "--dry-run" ]]; then
  echo ""
  echo "Running cloud-nuke in DRY-RUN mode (no resources will be deleted)."
  echo "Regions: ${REGIONS}"
  echo ""
  cloud-nuke aws \
    --region "${REGIONS//,/ --region }" \
    --dry-run \
    --log-level info
else
  echo ""
  echo "Running cloud-nuke in DESTROY mode."
  echo "Regions: ${REGIONS}"
  echo ""
  cloud-nuke aws \
    --region "${REGIONS//,/ --region }" \
    --log-level info \
    --force
fi

echo ""
echo "=============================================================================="
echo "Done. Remember to:"
echo "  1. Re-run terraform init in each affected layer"
echo "  2. Inspect state drift with 'terraform plan'"
echo "  3. Either re-apply or remove resources from state with 'terraform state rm'"
echo "=============================================================================="
