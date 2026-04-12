#!/usr/bin/env bash
# =============================================================================
# configure-github.sh — Set GitHub repository secrets and variables from config
# =============================================================================
# This script reads config/landing-zone.yaml and configures the GitHub
# repository with the secrets and variables needed by CI/CD workflows.
#
# What it sets:
#   - Secret  LANDING_ZONE_CONFIG : entire config.yaml content (used by workflows
#     to write config/landing-zone.yaml on the runner)
#
# Prerequisites:
#   - gh CLI installed and authenticated (gh auth login)
#   - config/landing-zone.yaml exists and is populated
#
# Usage:
#   ./scripts/configure-github.sh
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/config/landing-zone.yaml"

# --- Validate prerequisites ---

if ! command -v gh &>/dev/null; then
  echo "ERROR: gh CLI is required but not found. Install: brew install gh" >&2
  exit 1
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: ${CONFIG_FILE} not found." >&2
  exit 1
fi

gh auth status &>/dev/null || {
  echo "ERROR: gh CLI is not authenticated. Run: gh auth login" >&2
  exit 1
}

REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
echo "Repository: ${REPO}"
echo ""

# --- Set secret: entire config.yaml ---
echo "Setting secret LANDING_ZONE_CONFIG..."
gh secret set LANDING_ZONE_CONFIG < "${CONFIG_FILE}"
echo "  Done."

echo ""
echo "GitHub configuration complete."
echo ""
echo "Verify:"
echo "  gh secret list"
