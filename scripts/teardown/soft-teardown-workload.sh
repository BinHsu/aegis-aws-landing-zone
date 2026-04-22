#!/usr/bin/env bash
# =============================================================================
# soft-teardown-workload.sh — destroy workload layers only
# =============================================================================
# Destroys workload Terraservices layers (workloads, platform, network) in a
# specified environment. Preserves the bootstrap layer, shared-services
# account, security/logarchive accounts, and the Control Tower landing zone.
#
# Use this at the end of a session to return cost to baseline:
#   - Before:  NAT Gateway + EKS control plane + EC2 nodes running = ~$5/day
#   - After:   ~$5/month (CT + Config + CloudTrail baseline)
#
# Safe to run multiple times. Layers that don't exist are skipped gracefully.
#
# Usage:
#   export AWS_PROFILE=aegis-staging-admin
#   aws sso login --sso-session aegis
#   ./scripts/teardown/soft-teardown-workload.sh staging
#
# See ADR-009 for the full teardown strategy.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV="${1:-}"

# Workload layers in destruction order (reverse of apply order).
# Bootstrap is intentionally NOT in this list.
#
# Order rationale:
#   observability — first, so grafana-operator finalizers on GrafanaDashboard /
#                   GrafanaContactPoint / GrafanaNotificationPolicy* CRDs run
#                   while the operator pod is alive. Skipping this step leaves
#                   orphan dashboards / contact points on the Grafana Cloud
#                   stack (ADR-022 §Teardown). The layer loop below invokes
#                   the CRD pre-delete helper before `terraform destroy` when
#                   the current layer is observability.
#   workloads      — second, provides the `aegis` namespace that observability
#                   pulls the team-webhooks Secret into.
#   platform       — third, tears down EKS + Karpenter (see Karpenter quiesce
#                   logic below).
#   network        — last, removes VPC after ENIs are reclaimed.
LAYERS=(observability workloads platform network)

# --- Validation ---

if [[ ! -t 0 ]]; then
  echo "ERROR: This script requires an interactive TTY. Cannot run via pipe or CI." >&2
  exit 1
fi

if [[ -z "${ENV}" ]]; then
  echo "Usage: $0 <environment>" >&2
  echo "Example: $0 staging" >&2
  exit 1
fi

# Allowlist — only workload environments can be soft-torn-down
case "${ENV}" in
  staging|prod|sandbox|sandbox-*)
    ;;
  *)
    echo "ERROR: '${ENV}' is not an allowed workload environment." >&2
    echo "Allowed: staging, prod, sandbox, sandbox-*" >&2
    echo "For foundation accounts (management/shared/security/logarchive)," >&2
    echo "use hard-teardown-landing-zone.sh (rare, triple-confirmed)." >&2
    exit 1
    ;;
esac

# Git clean check — refuse if uncommitted changes exist
cd "${REPO_ROOT}"
if ! git diff-index --quiet HEAD --; then
  echo "ERROR: Git working tree has uncommitted changes. Commit or stash first." >&2
  git status --short >&2
  exit 1
fi

# AWS_PROFILE check
if [[ -z "${AWS_PROFILE:-}" ]]; then
  echo "ERROR: AWS_PROFILE not set. Export: AWS_PROFILE=aegis-${ENV}-admin" >&2
  exit 1
fi

EXPECTED_PROFILE="aegis-${ENV}-admin"
if [[ "${AWS_PROFILE}" != "${EXPECTED_PROFILE}" ]]; then
  echo "ERROR: AWS_PROFILE is '${AWS_PROFILE}', expected '${EXPECTED_PROFILE}'." >&2
  exit 1
fi

# Verify caller identity matches the expected account
CONFIG_ACCT=$(python3 -c "
import yaml
c = yaml.safe_load(open('${REPO_ROOT}/config/landing-zone.yaml'))
print(c['accounts']['${ENV}']['id'])
" 2>/dev/null) || {
  echo "ERROR: Could not read accounts.${ENV}.id from config/landing-zone.yaml" >&2
  exit 1
}

if [[ -z "${CONFIG_ACCT}" ]]; then
  echo "ERROR: accounts.${ENV}.id is empty in config/landing-zone.yaml" >&2
  exit 1
fi

ACTUAL_ACCT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  echo "ERROR: 'aws sts get-caller-identity' failed. Run 'aws sso login --sso-session aegis'." >&2
  exit 1
}

if [[ "${ACTUAL_ACCT}" != "${CONFIG_ACCT}" ]]; then
  echo "ERROR: Current AWS session is account ${ACTUAL_ACCT}, expected ${CONFIG_ACCT}." >&2
  exit 1
fi

# --- Confirmation ---

echo ""
echo "=============================================================================="
echo "SOFT TEARDOWN — ${ENV} (${CONFIG_ACCT})"
echo "=============================================================================="
echo ""
echo "Will destroy workload layers (in order):"
for LAYER in "${LAYERS[@]}"; do
  LAYER_DIR="${REPO_ROOT}/terraform/environments/${ENV}/${LAYER}"
  if [[ -d "${LAYER_DIR}" ]]; then
    echo "  - ${ENV}/${LAYER}  (will be destroyed)"
  else
    echo "  - ${ENV}/${LAYER}  (does not exist, will skip)"
  fi
done
echo ""
echo "Preserved:"
echo "  - ${ENV}/bootstrap (account alias, OIDC provider, CI role)"
echo "  - Other accounts (management, shared, security, logarchive, prod/staging)"
echo "  - Shared services (Terraform state bucket, IPAM)"
echo "  - Control Tower landing zone"
echo ""
echo "Type the environment name '${ENV}' to confirm, anything else to abort:"
read -r CONFIRM
if [[ "${CONFIRM}" != "${ENV}" ]]; then
  echo "Aborted."
  exit 1
fi

# --- Destruction ---

# Pre-delete grafana-operator-managed CRDs. Same contract as the CI workflow
# (see .github/workflows/terraform-teardown-workload.yml step "Pre-delete
# grafana-operator CRDs"). Tolerant of "cluster already gone" / "CRD not
# found" — soft teardown must be re-runnable after partial failures.
grafana_operator_pre_delete() {
  local cluster_name
  cluster_name=$(aws eks list-clusters \
    --region eu-central-1 \
    --query "clusters[?contains(@, 'primary')] | [0]" \
    --output text 2>/dev/null || echo "None")
  if [[ "${cluster_name}" == "None" || -z "${cluster_name}" || "${cluster_name}" == "null" ]]; then
    echo "  (no primary EKS cluster found — skipping CRD pre-delete)"
    return 0
  fi
  if ! aws eks update-kubeconfig \
         --region eu-central-1 --name "${cluster_name}" >/dev/null 2>&1; then
    echo "  (could not fetch kubeconfig — skipping CRD pre-delete)"
    return 0
  fi

  echo "  Deleting grafana-operator-managed CRs (2m timeout per kind)..."
  for kind in grafanadashboard grafanacontactpoint grafananotificationpolicyroute grafananotificationpolicy grafanamutetiming; do
    kubectl delete "${kind}" --all -A --timeout=2m --ignore-not-found 2>/dev/null || true
  done
  kubectl delete grafana --all -A --timeout=1m --ignore-not-found 2>/dev/null || true

  echo "  Waiting for finalizers to flush (up to 2 min)..."
  local i remaining
  for i in $(seq 1 12); do
    remaining=$(kubectl get grafanadashboard,grafanacontactpoint,grafananotificationpolicyroute,grafananotificationpolicy,grafana -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${remaining}" == "0" ]]; then
      echo "  All grafana-operator CRs flushed."
      return 0
    fi
    echo "  ${remaining} CRs still present; waiting 10s (attempt ${i}/12)"
    sleep 10
  done
  echo "  WARNING: finalizers did not complete in 2m. Proceeding — remove any orphan resources manually via the Grafana Cloud portal."
}

echo ""
for LAYER in "${LAYERS[@]}"; do
  LAYER_DIR="${REPO_ROOT}/terraform/environments/${ENV}/${LAYER}"
  if [[ ! -d "${LAYER_DIR}" ]]; then
    echo "Skipping ${ENV}/${LAYER}: directory does not exist."
    continue
  fi

  echo "------------------------------------------------------------------------"
  echo "Destroying ${ENV}/${LAYER}..."
  echo "------------------------------------------------------------------------"

  if [[ "${LAYER}" == "observability" ]]; then
    grafana_operator_pre_delete
  fi

  cd "${LAYER_DIR}"
  terraform init -input=false -upgrade
  terraform destroy -auto-approve -input=false
  echo ""
done

echo "=============================================================================="
echo "Soft teardown complete for ${ENV}."
echo "Bootstrap layer preserved. Run this script again at the next session end."
echo "=============================================================================="
