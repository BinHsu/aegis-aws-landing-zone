#!/usr/bin/env bash
# =============================================================================
# hard-teardown-landing-zone.sh — one-time project decommission
# =============================================================================
# Destroys EVERYTHING:
#   - All workload layers in staging and prod
#   - Management SCPs, shared IPAM, all bootstrap layers
#   - Control Tower landing zone
#   - All member accounts via CloseAccount API
#
# After this runs, member accounts enter AWS's 90-day suspension period and
# cannot be reopened or reused. This is project-end, not session-end.
#
# Safeguards (triple-confirmed):
#   1. Full-sentence acknowledgement of the 90-day rule
#   2. Type the management account ID (forces operator to switch windows)
#   3. Type a specific destruction phrase
#   4. Ten-second final countdown with cancel option
#
# Refuses to run in CI. Refuses to run via pipe. Requires local TTY.
#
# The management account itself cannot be closed via CLI — the script prints
# instructions for manual closure via root login as the last step.
#
# See ADR-009 for the full rationale.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- Anti-CI + anti-pipe ---

if [[ -n "${CI:-}" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -n "${GITLAB_CI:-}" ]] || \
   [[ -n "${JENKINS_URL:-}" ]] || [[ -n "${BUILDKITE:-}" ]] || [[ -n "${CIRCLECI:-}" ]]; then
  echo "ERROR: CI environment detected. This script is local-terminal-only by design." >&2
  exit 1
fi

if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
  echo "ERROR: Requires a real interactive TTY on both stdin and stdout." >&2
  exit 1
fi

# --- Read config ---

if [[ ! -f "${REPO_ROOT}/config/landing-zone.yaml" ]]; then
  echo "ERROR: config/landing-zone.yaml not found." >&2
  exit 1
fi

MGMT_ID=$(python3 -c "
import yaml
c = yaml.safe_load(open('${REPO_ROOT}/config/landing-zone.yaml'))
print(c['accounts']['management']['id'])
")

ALL_MEMBER_IDS=$(python3 -c "
import yaml
c = yaml.safe_load(open('${REPO_ROOT}/config/landing-zone.yaml'))
for name, acct in c['accounts'].items():
    if name != 'management' and acct['id']:
        print(acct['id'])
")

# --- Confirmation 1: full-sentence acknowledgement ---

REQUIRED_SENTENCE="I understand closed accounts are locked for 90 days and the emails cannot be reused"

echo ""
echo "=============================================================================="
echo "HARD TEARDOWN — PROJECT DECOMMISSION"
echo "=============================================================================="
echo ""
echo "This destroys the ENTIRE landing zone and closes all member accounts."
echo "Closed accounts enter AWS's 90-day suspension period."
echo ""
echo "Type the following sentence EXACTLY to proceed:"
echo ""
echo "  ${REQUIRED_SENTENCE}"
echo ""
read -r INPUT_SENTENCE
if [[ "${INPUT_SENTENCE}" != "${REQUIRED_SENTENCE}" ]]; then
  echo "Aborted (sentence did not match)."
  exit 1
fi

# --- Confirmation 2: management account ID ---

echo ""
echo "Type the management account ID (12 digits):"
read -r INPUT_ACCT
if [[ "${INPUT_ACCT}" != "${MGMT_ID}" ]]; then
  echo "Aborted (account ID did not match)."
  exit 1
fi

# --- Confirmation 3: destruction phrase ---

REQUIRED_PHRASE="permanently destroy aegis landing zone"

echo ""
echo "Type the destruction phrase EXACTLY:"
echo ""
echo "  ${REQUIRED_PHRASE}"
echo ""
read -r INPUT_PHRASE
if [[ "${INPUT_PHRASE}" != "${REQUIRED_PHRASE}" ]]; then
  echo "Aborted (phrase did not match)."
  exit 1
fi

# --- 10-second countdown with cancel ---

echo ""
echo "Last chance to cancel. Starting destruction in 10 seconds."
echo "Press Ctrl-C to abort."
for i in 10 9 8 7 6 5 4 3 2 1; do
  echo -n "${i}... "
  sleep 1
done
echo ""
echo ""
echo "Proceeding with destruction."
echo ""

# --- Destruction ---

# Helper: destroy a layer if the directory exists
destroy_layer() {
  local ACCT="$1"
  local ENV="$2"
  local LAYER="$3"
  local LAYER_DIR="${REPO_ROOT}/terraform/environments/${ENV}/${LAYER}"

  if [[ ! -d "${LAYER_DIR}" ]]; then
    return
  fi

  echo "Destroying ${ENV}/${LAYER} (account ${ACCT})..."
  (
    cd "${LAYER_DIR}"
    AWS_PROFILE="aegis-${ENV}-admin" terraform init -input=false -upgrade
    AWS_PROFILE="aegis-${ENV}-admin" terraform destroy -auto-approve -input=false
  )
}

# Workload environments: all layers top-down
for ENV in staging prod; do
  ACCT=$(python3 -c "
import yaml
c = yaml.safe_load(open('${REPO_ROOT}/config/landing-zone.yaml'))
print(c['accounts']['${ENV}']['id'])
")
  [[ -z "${ACCT}" ]] && continue

  for LAYER in workloads platform network bootstrap; do
    destroy_layer "${ACCT}" "${ENV}" "${LAYER}"
  done
done

# Shared services
destroy_layer "shared" "shared" "aft"
destroy_layer "shared" "shared" "ipam"
destroy_layer "shared" "shared" "bootstrap"

# Management (SCPs before bootstrap so SCPs don't interfere with closure)
destroy_layer "management" "management" "scps"
destroy_layer "management" "management" "bootstrap"

# --- Control Tower decommission ---

echo ""
echo "Decommissioning Control Tower landing zone..."
LZ_ARN=$(AWS_PROFILE="aegis-management-admin" \
  aws controltower list-landing-zones --region eu-central-1 \
  --query 'landingZones[0].arn' --output text)

if [[ -n "${LZ_ARN}" ]] && [[ "${LZ_ARN}" != "None" ]]; then
  AWS_PROFILE="aegis-management-admin" \
    aws controltower delete-landing-zone \
    --landing-zone-identifier "${LZ_ARN}" \
    --region eu-central-1
  echo "Control Tower deletion initiated. This takes approximately 30 minutes."
else
  echo "No Control Tower landing zone found. Skipping decommission."
fi

# --- Close member accounts ---

echo ""
echo "Closing member accounts via CloseAccount API..."
while IFS= read -r ACCT; do
  [[ -z "${ACCT}" ]] && continue
  echo "  Closing ${ACCT}..."
  AWS_PROFILE="aegis-management-admin" \
    aws organizations close-account --account-id "${ACCT}" || \
    echo "  WARNING: CloseAccount failed for ${ACCT}. Continue manually."
done <<< "${ALL_MEMBER_IDS}"

# --- Management account: manual step ---

echo ""
echo "=============================================================================="
echo "Automated destruction complete."
echo "=============================================================================="
echo ""
echo "REMAINING MANUAL STEP:"
echo ""
echo "The management account (${MGMT_ID}) cannot be closed via CLI. To close it:"
echo ""
echo "  1. Sign in to the management account via root user (not SSO)."
echo "  2. Navigate to Account Settings → Close Account."
echo "  3. Follow the prompts."
echo ""
echo "All member accounts are now suspended. They will be permanently deleted"
echo "in 90 days. Their email addresses cannot be reused until then."
echo ""
echo "Project end. Goodbye."
