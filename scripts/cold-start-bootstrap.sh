#!/usr/bin/env bash
# ============================================================================
# cold-start-bootstrap.sh — seed + adopt the CI bootstrap IAM roles into a
# brand-new (cold) member account's Terraform bootstrap layer
# ============================================================================
#
# WHY THIS EXISTS (chicken-and-egg):
#   A new member account's bootstrap layer creates the roles GitHub Actions
#   CI needs to operate on that account: gh-tf-plan, gh-tf-apply-baseline,
#   aegis-emergency-break-glass (+ the GitHub OIDC provider + account alias).
#   CI can only assume roles that already exist, so the FIRST apply against a
#   cold account cannot run through CI — there is nothing yet for it to
#   assume. It has to run from a human's local credentials.
#
#   The Terraform state bucket only allows gh-tf-*, aegis-emergency-*, and
#   PlatformAdmin-SSO principals to write state — and AWSControlTowerExecution
#   (the only role a human can assume INTO a fresh Control-Tower-vended
#   account) is deliberately NOT on that allow-list. A normal S3-backed
#   `terraform apply` under CT-exec therefore fails on state access before it
#   ever gets to create a resource.
#
#   This script resolves both constraints in two phases, run against the
#   SAME account:
#
#     SEED  — apply with LOCAL (throwaway) state, under CT-exec credentials,
#             to create the 8 resources for real in the account. backend.tf
#             is moved aside for the duration (Terraform's backend block
#             cannot be parameterized) and restored on exit no matter how the
#             script terminates.
#
#     ADOPT — apply with the REAL S3 state, backend authenticated as the
#             ambient AWS profile (PlatformAdmin, who CAN write state), but
#             the PROVIDER (resource operations) temporarily assumes CT-exec
#             via a generated `*_override.tf` so it can read/import the
#             resources SEED just created. `-var=adopt_seeded_iam_roles=true`
#             switches the environment's `iam-survivor-import.tf` from
#             CREATE-fresh to IMPORT-existing, so nothing collides
#             (EntityAlreadyExists).
#
#   After ADOPT, the S3 state matches reality and var.adopt_seeded_iam_roles
#   reverts to its committed default (false) on the next plan — an ordinary
#   CI apply (gh-tf-apply-baseline, real S3 state, adopt=false) then sees no
#   diff.
#
# See docs/runbooks/002-cold-account-bootstrap.md for the full narrative and
# a worked example, and issue #309 for the tracked future work to eliminate
# this manual step (AFT-style CI-native cold-account bootstrap).
#
# USAGE:
#   scripts/cold-start-bootstrap.sh --env-dir <name> --mode <seed|adopt|both> \
#       [--account-id <12-digit-id>] [--profile <aws-profile-name>]
#
#   --env-dir     Directory name under terraform/environments/<env-dir>/bootstrap
#                 (also the accounts.<env-dir> key in config/landing-zone.yaml,
#                 unless --account-id overrides it). Example: security, logarchive.
#   --mode        seed  - create the 8 resources via CT-exec + local state.
#                 adopt - import the 8 resources into S3 state via the ambient
#                         profile's backend + a temporary CT-exec provider
#                         override.
#                 both  - seed then adopt in one run, same account.
#   --account-id  12-digit AWS account id. Optional — defaults to
#                 accounts.<env-dir>.id read from config/landing-zone.yaml.
#   --profile     AWS CLI profile that can (a) assume AWSControlTowerExecution
#                 into the target account and (b) write the S3 state bucket
#                 (ambient PlatformAdmin). Default: aegis-management-admin.
#
#   Example:
#     ./scripts/cold-start-bootstrap.sh --env-dir security --mode both
#     ./scripts/cold-start-bootstrap.sh --env-dir logarchive --mode adopt
#
# PREREQUISITES:
#   - `aws sso login --sso-session aegis` already run.
#   - The target environment's Terraform code already exists at
#     terraform/environments/<env-dir>/bootstrap/, including a
#     var.adopt_seeded_iam_roles-gated iam-survivor-import.tf — see
#     terraform/environments/prod/bootstrap/iam-survivor-import.tf for the
#     pattern this script expects.
#   - aws cli v2, jq, python3 (with pyyaml), terraform >= 1.10 on PATH.
#
# SAFETY FEATURES:
#   - Verifies the assumed AWSControlTowerExecution identity's account id
#     matches the expected account BEFORE any init/plan/apply, in both modes.
#   - terraform plan always runs and is shown before apply; apply requires
#     typing "yes" at an interactive prompt — no --auto-approve, no
#     non-interactive path.
#   - SEED moves backend.tf aside for local state and restores it via a trap
#     on ANY exit (including Ctrl-C), so a cold account is never left
#     without its backend.tf; throwaway local state is deleted after use.
#   - ADOPT writes a temporary `*_override.tf` (Terraform's override-file
#     naming convention, so it merges with rather than duplicates the
#     committed `provider "aws"` block) and removes it via a trap on ANY
#     exit.
#   - The committed .terraform.lock.hcl is never touched — only .terraform/
#     (the provider plugin cache) and throwaway local state are cleared.
# ============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/config/landing-zone.yaml"
CT_EXEC_ROLE_NAME="AWSControlTowerExecution"

usage() {
  cat <<'EOF'
Usage: cold-start-bootstrap.sh --env-dir <name> --mode <seed|adopt|both>
                                [--account-id <12-digit-id>] [--profile <aws-profile>]

  --env-dir     terraform/environments/<env-dir>/bootstrap (e.g. security, logarchive)
  --mode        seed | adopt | both
  --account-id  optional; defaults to accounts.<env-dir>.id in config/landing-zone.yaml
  --profile     optional; default aegis-management-admin

See the script's header comment and docs/runbooks/002-cold-account-bootstrap.md
for the full procedure.
EOF
}

ENV_DIR=""
MODE=""
ACCOUNT_ID=""
PROFILE="aegis-management-admin"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-dir)
      ENV_DIR="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    --account-id)
      ACCOUNT_ID="$2"
      shift 2
      ;;
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${ENV_DIR}" ]]; then
  echo "ERROR: --env-dir is required." >&2
  usage >&2
  exit 1
fi

case "${MODE}" in
  seed | adopt | both) ;;
  *)
    echo "ERROR: --mode must be one of: seed, adopt, both." >&2
    usage >&2
    exit 1
    ;;
esac

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: ${CONFIG_FILE} not found." >&2
  echo "Copy config/landing-zone.example.yaml to config/landing-zone.yaml and fill in your values." >&2
  exit 1
fi

BOOTSTRAP_DIR="${REPO_ROOT}/terraform/environments/${ENV_DIR}/bootstrap"
if [[ ! -d "${BOOTSTRAP_DIR}" ]]; then
  echo "ERROR: ${BOOTSTRAP_DIR} does not exist." >&2
  echo "This script only bootstraps an EXISTING Terraform environment's cold IAM" >&2
  echo "roles — it does not scaffold the environment itself. See issue #303 for" >&2
  echo "the security/logarchive precedent." >&2
  exit 1
fi

if [[ -z "${ACCOUNT_ID}" ]]; then
  ACCOUNT_ID="$(python3 -c "
import yaml
with open('${CONFIG_FILE}') as f:
    c = yaml.safe_load(f)
acct = (c.get('accounts') or {}).get('${ENV_DIR}') or {}
print(acct.get('id', '') or '')
" 2>/dev/null)"
fi

if [[ -z "${ACCOUNT_ID}" || ! "${ACCOUNT_ID}" =~ ^[0-9]{12}$ ]]; then
  echo "ERROR: could not resolve a 12-digit account id for env-dir '${ENV_DIR}'." >&2
  echo "Pass --account-id explicitly, or set accounts.${ENV_DIR}.id in config/landing-zone.yaml." >&2
  exit 1
fi

echo "=================================================================="
echo "env-dir=${ENV_DIR}  account=${ACCOUNT_ID}  mode=${MODE}  profile=${PROFILE}"
echo "=================================================================="
echo "Source profile identity:"
aws sts get-caller-identity --profile "${PROFILE}" --query Arn --output text

# --- shared: assume AWSControlTowerExecution and verify the target account ---
#
# Populates CT_EXEC_AK / CT_EXEC_SK / CT_EXEC_ST on success. FATAL on any
# mismatch — this is the "identity verification before any apply" gate for
# both SEED and ADOPT.
assume_ct_exec() {
  local creds live_acct
  creds="$(aws sts assume-role \
    --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${CT_EXEC_ROLE_NAME}" \
    --role-session-name "cold-start-bootstrap" \
    --profile "${PROFILE}" \
    --query 'Credentials' --output json)"
  CT_EXEC_AK="$(jq -r '.AccessKeyId' <<<"${creds}")"
  CT_EXEC_SK="$(jq -r '.SecretAccessKey' <<<"${creds}")"
  CT_EXEC_ST="$(jq -r '.SessionToken' <<<"${creds}")"
  if [[ -z "${CT_EXEC_AK}" || "${CT_EXEC_AK}" == "null" ]]; then
    echo "FATAL: failed to assume ${CT_EXEC_ROLE_NAME} into ${ACCOUNT_ID}." >&2
    return 1
  fi

  live_acct="$(AWS_ACCESS_KEY_ID="${CT_EXEC_AK}" \
    AWS_SECRET_ACCESS_KEY="${CT_EXEC_SK}" \
    AWS_SESSION_TOKEN="${CT_EXEC_ST}" \
    aws sts get-caller-identity --query Account --output text)"
  if [[ "${live_acct}" != "${ACCOUNT_ID}" ]]; then
    echo "FATAL: ${CT_EXEC_ROLE_NAME} resolved to account ${live_acct}, expected ${ACCOUNT_ID}. Aborting." >&2
    return 1
  fi
  echo "confirmed identity: arn:aws:sts::${ACCOUNT_ID}:assumed-role/${CT_EXEC_ROLE_NAME}/cold-start-bootstrap"
}

# --- SEED: local state, CT-exec creds, backend.tf moved aside -------------
seed() {
  echo
  echo "=================================================================="
  echo ">>> SEED: ${ENV_DIR} (${ACCOUNT_ID})"
  echo "=================================================================="

  echo "--- assuming ${CT_EXEC_ROLE_NAME} into ${ACCOUNT_ID} ---"
  assume_ct_exec
  export AWS_ACCESS_KEY_ID="${CT_EXEC_AK}" AWS_SECRET_ACCESS_KEY="${CT_EXEC_SK}" AWS_SESSION_TOKEN="${CT_EXEC_ST}"

  cd "${BOOTSTRAP_DIR}" || exit 1

  local backend_moved=0
  restore_seed_state() {
    if [[ -f backend.tf.seedbak && ${backend_moved} -eq 1 ]]; then
      mv backend.tf.seedbak backend.tf
      echo "(restored backend.tf)"
    fi
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  }
  trap restore_seed_state RETURN

  if [[ -f backend.tf ]]; then
    mv backend.tf backend.tf.seedbak
    backend_moved=1
  fi

  # Keep the committed .terraform.lock.hcl (pins provider versions); only
  # clear the backend/plugin cache and any prior throwaway local state.
  rm -rf .terraform terraform.tfstate terraform.tfstate.backup

  echo "--- terraform init (local state; backend.tf removed for seed) ---"
  terraform init -input=false

  echo "--- terraform plan (review what will be created) ---"
  local plan_file="/tmp/cold-start-${ENV_DIR}-seed.tfplan"
  terraform plan -input=false -out="${plan_file}"

  echo
  read -r -p ">>> Apply SEED to ${ENV_DIR} (${ACCOUNT_ID})? Type 'yes' to proceed: " confirm
  if [[ "${confirm}" != "yes" ]]; then
    echo "Skipped SEED for ${ENV_DIR} (no apply)."
    return 0
  fi

  echo "--- terraform apply ---"
  terraform apply -input=false "${plan_file}"

  echo "--- roles now present in ${ENV_DIR}: ---"
  aws iam list-roles \
    --query "Roles[?starts_with(RoleName,'gh-tf-')||starts_with(RoleName,'aegis-emergency-')].RoleName" \
    --output text

  # Clean the throwaway local state so it can never be mistaken for real state.
  rm -f terraform.tfstate terraform.tfstate.backup
  echo ">>> SEED complete for ${ENV_DIR}."
}

# --- ADOPT: real S3 state (ambient profile), CT-exec provider override ----
adopt() {
  echo
  echo "=================================================================="
  echo ">>> ADOPT: ${ENV_DIR} (${ACCOUNT_ID}) into S3 state"
  echo "=================================================================="

  echo "--- verifying ${CT_EXEC_ROLE_NAME} still resolves to ${ACCOUNT_ID} ---"
  assume_ct_exec
  unset CT_EXEC_AK CT_EXEC_SK CT_EXEC_ST

  echo "Ambient (backend) identity: $(aws sts get-caller-identity --profile "${PROFILE}" --query Arn --output text)"

  cd "${BOOTSTRAP_DIR}" || exit 1

  # Terraform override-file naming convention (*_override.tf): this MERGES
  # with the committed `provider "aws" {}` block instead of conflicting with
  # it, adding an assume_role for resource operations while the backend block
  # (declared separately in backend.tf) keeps using the ambient profile.
  local override_file="${BOOTSTRAP_DIR}/cold_start_adopt_override.tf"
  cleanup_adopt() {
    rm -f "${override_file}"
    unset AWS_PROFILE
  }
  trap cleanup_adopt RETURN

  cat >"${override_file}" <<EOF
# TEMPORARY — generated by scripts/cold-start-bootstrap.sh --mode adopt.
# Provider assumes ${CT_EXEC_ROLE_NAME} for resource operations while the S3
# backend authenticates as the ambient profile (${PROFILE}). Removed
# automatically when the script exits. Do not commit this file.
provider "aws" {
  assume_role {
    role_arn     = "arn:aws:iam::${ACCOUNT_ID}:role/${CT_EXEC_ROLE_NAME}"
    session_name = "cold-start-adopt"
  }
}
EOF

  export AWS_PROFILE="${PROFILE}"
  rm -rf .terraform

  echo "--- terraform init (S3 backend, ambient profile ${PROFILE}) ---"
  terraform init -input=false

  echo "--- terraform plan (adopt_seeded_iam_roles=true: expect 8 imports, no other changes) ---"
  local plan_file="/tmp/cold-start-${ENV_DIR}-adopt.tfplan"
  terraform plan -input=false -var="adopt_seeded_iam_roles=true" -out="${plan_file}"

  echo
  read -r -p ">>> Apply ADOPT to ${ENV_DIR} (${ACCOUNT_ID})? Type 'yes' to proceed: " confirm
  if [[ "${confirm}" != "yes" ]]; then
    echo "Skipped ADOPT for ${ENV_DIR} (no apply)."
    return 0
  fi

  echo "--- terraform apply ---"
  terraform apply -input=false "${plan_file}"

  echo "--- state now contains: ---"
  terraform state list

  echo ">>> ADOPT complete for ${ENV_DIR} (state in S3)."
}

# --- exit-safety net: catches anything the per-function traps miss (e.g. a
# kill -9 between the two RETURN traps in --mode both) ---
cleanup_all() {
  if [[ -f "${BOOTSTRAP_DIR}/backend.tf.seedbak" ]]; then
    mv "${BOOTSTRAP_DIR}/backend.tf.seedbak" "${BOOTSTRAP_DIR}/backend.tf"
    echo "(exit-restore: ${BOOTSTRAP_DIR}/backend.tf)"
  fi
  rm -f "${BOOTSTRAP_DIR}/cold_start_adopt_override.tf"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE CT_EXEC_AK CT_EXEC_SK CT_EXEC_ST
}
trap cleanup_all EXIT INT TERM

case "${MODE}" in
  seed)
    seed
    ;;
  adopt)
    adopt
    ;;
  both)
    seed
    adopt
    ;;
esac

echo
echo "=================================================================="
echo "cold-start-bootstrap.sh (${MODE}) done for ${ENV_DIR} (${ACCOUNT_ID})."
echo "Next: a normal CI apply (gh-tf-apply-baseline, adopt_seeded_iam_roles"
echo "defaults to false) against this environment should now show NO changes."
echo "See docs/runbooks/002-cold-account-bootstrap.md and issue #309 (future"
echo "AFT-style automation of this procedure)."
echo "=================================================================="
