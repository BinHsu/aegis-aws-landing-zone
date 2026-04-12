#!/usr/bin/env bash
# =============================================================================
# configure-backends.sh — Sync backend.tf files with config/landing-zone.yaml
# =============================================================================
# Terraform backend blocks cannot use variables or locals (language limitation).
# This script reads your config/landing-zone.yaml and replaces the hardcoded
# bucket name and region in all backend.tf files across the repository.
#
# Run this once after:
#   1. Forking the repository
#   2. Filling in config/landing-zone.yaml with your real values
#   3. Creating the shared account and state bucket
#
# The script is idempotent — safe to run multiple times.
#
# Usage:
#   ./scripts/configure-backends.sh
#
# Prerequisites:
#   - python3 (comes with macOS and most Linux distributions)
#   - config/landing-zone.yaml must exist and have accounts.shared.id populated
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/config/landing-zone.yaml"

# --- Validate prerequisites ---

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required but not found." >&2
  exit 1
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: ${CONFIG_FILE} not found." >&2
  echo "Copy config/landing-zone.example.yaml to config/landing-zone.yaml and fill in your values." >&2
  exit 1
fi

# --- Extract values from config ---

read -r ORG_NAME SHARED_ID PRIMARY_REGION < <(python3 -c "
import yaml, sys
with open('${CONFIG_FILE}') as f:
    c = yaml.safe_load(f)
org = c['organization']['name']
shared_id = c['accounts']['shared']['id']
region = next(r['name'] for r in c['regions'] if r['role'] == 'primary')
print(org, shared_id, region)
" 2>/dev/null) || {
  # Fallback if PyYAML is not installed — use grep/awk
  ORG_NAME=$(python3 -c "
import json, re, sys
text = open('${CONFIG_FILE}').read()
# Minimal YAML parsing for flat keys
m = re.search(r'organization:\s*\n\s+name:\s*(\S+)', text)
print(m.group(1) if m else '')
")
  SHARED_ID=$(python3 -c "
import re
text = open('${CONFIG_FILE}').read()
# Find shared.id
block = text[text.find('shared:'):]
m = re.search(r'id:\s*\"?(\d{12})\"?', block)
print(m.group(1) if m else '')
")
  PRIMARY_REGION=$(python3 -c "
import re
text = open('${CONFIG_FILE}').read()
m = re.search(r'role:\s*primary', text)
if m:
    before = text[:m.start()]
    nm = list(re.finditer(r'name:\s*(\S+)', before))
    if nm: print(nm[-1].group(1))
")
}

# --- Validate extracted values ---

if [[ -z "${ORG_NAME}" ]]; then
  echo "ERROR: Could not read organization.name from config." >&2
  exit 1
fi

if [[ -z "${SHARED_ID}" || "${#SHARED_ID}" -ne 12 ]]; then
  echo "ERROR: accounts.shared.id must be a 12-digit AWS account ID." >&2
  echo "Current value: '${SHARED_ID}'" >&2
  exit 1
fi

if [[ -z "${PRIMARY_REGION}" ]]; then
  echo "ERROR: Could not determine primary region from config." >&2
  exit 1
fi

BUCKET_NAME="${ORG_NAME}-terraform-state-${SHARED_ID}"

echo "Configuration:"
echo "  Organization: ${ORG_NAME}"
echo "  Shared ID:    ${SHARED_ID}"
echo "  Region:       ${PRIMARY_REGION}"
echo "  Bucket:       ${BUCKET_NAME}"
echo ""

# --- Replace values in all backend.tf files ---

BACKEND_FILES=$(find "${REPO_ROOT}/terraform" -name "backend.tf" -not -path "*/.terraform/*")
COUNT=0

for f in ${BACKEND_FILES}; do
  if grep -q 'backend "s3"' "$f"; then
    # Replace bucket value
    sed -i '' -E "s|bucket[[:space:]]*=[[:space:]]*\"[^\"]*\"|bucket       = \"${BUCKET_NAME}\"|" "$f"
    # Replace region value
    sed -i '' -E "s|region[[:space:]]*=[[:space:]]*\"[^\"]*\"|region       = \"${PRIMARY_REGION}\"|" "$f"
    REL_PATH="${f#${REPO_ROOT}/}"
    echo "  Updated: ${REL_PATH}"
    COUNT=$((COUNT + 1))
  fi
done

echo ""
echo "Done. Updated ${COUNT} backend.tf file(s)."
echo ""
echo "Next steps:"
echo "  1. cd terraform/environments/<account>/<layer>"
echo "  2. terraform init"
echo "  3. terraform plan"
