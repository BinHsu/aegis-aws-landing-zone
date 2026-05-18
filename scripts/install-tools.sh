#!/usr/bin/env bash
# =============================================================================
# install-tools.sh — project-local pinned toolchain
# =============================================================================
# Fetches the auxiliary CLI tools this repo expects into a gitignored ./bin/.
# No brew, no apt, no sudo, nothing in /usr/local — a contributor runs this
# once and gets the same toolchain as everyone else. The Makefile prepends
# ./bin to PATH.
#
# Tools installed:
#   tflint       Terraform linter
#   gitleaks     secret scanner (also wired into .pre-commit-config.yaml)
#   kubeconform  Kubernetes manifest validator (k8s-manifests/)
#   jq           JSON processor (Makefile / scripting)
#
# NOT installed here: terraform itself. It is pinned via .terraform-version
# (1.14.8) and expected to be supplied by tfenv/asdf — a second terraform
# binary in ./bin/ would shadow that and cause version drift.
#
# Integrity model — trust on first use, then pinned:
#   The first run records each downloaded asset's SHA256 into scripts/tools.lock.
#   That lock file is committed. Every later run (and CI) verifies the download
#   against the committed checksum and aborts on mismatch — same idea as
#   go.sum / Cargo.lock.
#
# Usage:
#   ./scripts/install-tools.sh                # install + verify against lock
#   ./scripts/install-tools.sh --update-lock  # record checksums for new pins
#                                             # (then: git add scripts/tools.lock)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${REPO_ROOT}/bin"
LOCK_FILE="${REPO_ROOT}/scripts/tools.lock"

UPDATE_LOCK=0
[[ "${1:-}" == "--update-lock" ]] && UPDATE_LOCK=1

# --- pinned versions --------------------------------------------------------
# Bump a version here, then run with --update-lock and commit scripts/tools.lock.
TFLINT_VERSION="0.54.0"
GITLEAKS_VERSION="8.21.2"
KUBECONFORM_VERSION="0.6.7"
JQ_VERSION="1.7.1"

# --- platform detection -----------------------------------------------------
case "$(uname -s)" in
  Darwin) OS="darwin" ;;
  Linux)  OS="linux" ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="amd64" ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$BIN_DIR"

# --- checksum helpers -------------------------------------------------------
sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

lock_lookup() {  # key -> checksum (empty if absent)
  [[ -f "$LOCK_FILE" ]] || return 0
  awk -v k="$1" '$1==k {print $2}' "$LOCK_FILE"
}

lock_record() {  # key checksum -> rewrite lock entry
  local key="$1" sha="$2"
  if [[ -f "$LOCK_FILE" ]]; then
    grep -v "^${key} " "$LOCK_FILE" > "${LOCK_FILE}.tmp" 2>/dev/null || true
    mv "${LOCK_FILE}.tmp" "$LOCK_FILE"
  else
    printf '# tools.lock — SHA256 pins for scripts/install-tools.sh\n' > "$LOCK_FILE"
    printf '# Regenerate with: ./scripts/install-tools.sh --update-lock\n' >> "$LOCK_FILE"
  fi
  echo "${key} ${sha}" >> "$LOCK_FILE"
}

verify_or_record() {  # key file
  local key="$1" file="$2" actual expected
  actual="$(sha256 "$file")"
  expected="$(lock_lookup "$key")"
  if [[ -z "$expected" ]]; then
    if [[ "$UPDATE_LOCK" == "1" ]]; then
      lock_record "$key" "$actual"
      echo "    recorded checksum for ${key}"
    else
      echo "    ERROR: no checksum pinned for ${key}." >&2
      echo "    Run once: ./scripts/install-tools.sh --update-lock  (then commit scripts/tools.lock)" >&2
      exit 1
    fi
  elif [[ "$expected" != "$actual" ]]; then
    echo "    ERROR: checksum mismatch for ${key}" >&2
    echo "      expected ${expected}" >&2
    echo "      actual   ${actual}" >&2
    exit 1
  else
    echo "    checksum OK"
  fi
}

# --- per-tool installers ----------------------------------------------------
SKIPPED=()
INSTALLED=()

install_tflint() {
  if "${BIN_DIR}/tflint" --version 2>/dev/null | grep -q "${TFLINT_VERSION}"; then
    SKIPPED+=("tflint ${TFLINT_VERSION}"); return
  fi
  echo "tflint ${TFLINT_VERSION} (${OS}/${ARCH})"
  local key="tflint-${TFLINT_VERSION}-${OS}-${ARCH}"
  local url="https://github.com/terraform-linter/tflint/releases/download/v${TFLINT_VERSION}/tflint_${OS}_${ARCH}.zip"
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "${tmp}/tflint.zip"
  verify_or_record "$key" "${tmp}/tflint.zip"
  unzip -oq "${tmp}/tflint.zip" -d "$tmp"
  install -m 0755 "${tmp}/tflint" "${BIN_DIR}/tflint"
  rm -rf "$tmp"
  INSTALLED+=("tflint ${TFLINT_VERSION}")
}

install_gitleaks() {
  if "${BIN_DIR}/gitleaks" version 2>/dev/null | grep -q "${GITLEAKS_VERSION}"; then
    SKIPPED+=("gitleaks ${GITLEAKS_VERSION}"); return
  fi
  echo "gitleaks ${GITLEAKS_VERSION} (${OS}/${ARCH})"
  # gitleaks names amd64 assets "x64"
  local g_arch="$ARCH"; [[ "$ARCH" == "amd64" ]] && g_arch="x64"
  local key="gitleaks-${GITLEAKS_VERSION}-${OS}-${ARCH}"
  local url="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${OS}_${g_arch}.tar.gz"
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "${tmp}/gitleaks.tar.gz"
  verify_or_record "$key" "${tmp}/gitleaks.tar.gz"
  tar -xzf "${tmp}/gitleaks.tar.gz" -C "$tmp"
  install -m 0755 "${tmp}/gitleaks" "${BIN_DIR}/gitleaks"
  rm -rf "$tmp"
  INSTALLED+=("gitleaks ${GITLEAKS_VERSION}")
}

install_kubeconform() {
  if "${BIN_DIR}/kubeconform" -v 2>/dev/null | grep -q "${KUBECONFORM_VERSION}"; then
    SKIPPED+=("kubeconform ${KUBECONFORM_VERSION}"); return
  fi
  echo "kubeconform ${KUBECONFORM_VERSION} (${OS}/${ARCH})"
  local key="kubeconform-${KUBECONFORM_VERSION}-${OS}-${ARCH}"
  local url="https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-${OS}-${ARCH}.tar.gz"
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "${tmp}/kubeconform.tar.gz"
  verify_or_record "$key" "${tmp}/kubeconform.tar.gz"
  tar -xzf "${tmp}/kubeconform.tar.gz" -C "$tmp"
  install -m 0755 "${tmp}/kubeconform" "${BIN_DIR}/kubeconform"
  rm -rf "$tmp"
  INSTALLED+=("kubeconform ${KUBECONFORM_VERSION}")
}

install_jq() {
  if "${BIN_DIR}/jq" --version 2>/dev/null | grep -q "${JQ_VERSION}"; then
    SKIPPED+=("jq ${JQ_VERSION}"); return
  fi
  echo "jq ${JQ_VERSION} (${OS}/${ARCH})"
  local j_os="$OS"; [[ "$OS" == "darwin" ]] && j_os="macos"
  local key="jq-${JQ_VERSION}-${OS}-${ARCH}"
  local url="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-${j_os}-${ARCH}"
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "${tmp}/jq"
  verify_or_record "$key" "${tmp}/jq"
  install -m 0755 "${tmp}/jq" "${BIN_DIR}/jq"
  rm -rf "$tmp"
  INSTALLED+=("jq ${JQ_VERSION}")
}

# --- run --------------------------------------------------------------------
echo "Installing project toolchain into ${BIN_DIR}"
[[ "$UPDATE_LOCK" == "1" ]] && echo "(--update-lock: recording checksums into scripts/tools.lock)"
echo

install_tflint
install_gitleaks
install_kubeconform
install_jq

echo
echo "Summary:"
for t in "${INSTALLED[@]:-}"; do [[ -n "$t" ]] && echo "  installed  ${t}"; done
for t in "${SKIPPED[@]:-}";   do [[ -n "$t" ]] && echo "  up to date ${t}"; done
echo
echo "Add ./bin to PATH for this shell:   export PATH=\"${BIN_DIR}:\$PATH\""
echo "The Makefile does this automatically for its targets."
