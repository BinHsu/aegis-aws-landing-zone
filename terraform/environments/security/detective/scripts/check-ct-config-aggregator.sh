#!/usr/bin/env bash
# check-ct-config-aggregator.sh — probe for the Control-Tower-managed AWS
# Config aggregator in the current (audit/security) account.
#
# Backing script for the `check "ct_config_aggregator_exists"` block in
# ct-config-aggregator-check.tf (Epic #302 S4, issue #306). Read-only: one
# `describe-configuration-aggregators` call, nothing mutated.
#
# External-data-source protocol: reads (and discards) the query JSON on
# stdin, prints a single flat JSON object on stdout, and ALWAYS exits 0 —
# errors are reported in the payload (`found: "error"`) so a permission gap
# degrades to a check warning instead of failing the plan (see the .tf
# header for the CI boundary limitation).
#
# Usage: check-ct-config-aggregator.sh <region>

set -u

region="${1:-${AWS_REGION:-eu-central-1}}"

# Drain the external-provider query JSON from stdin (unused).
cat > /dev/null 2>&1 || true

json_escape() {
  # Minimal escaping for embedding in a JSON string value.
  printf '%s' "$1" | tr '\t\n"\\' '    '
}

names="$(aws configservice describe-configuration-aggregators \
  --region "$region" \
  --query 'ConfigurationAggregators[].ConfigurationAggregatorName' \
  --output text 2>&1)"
rc=$?

if [ "$rc" -ne 0 ]; then
  printf '{"found":"error","aggregators":"","detail":"describe-configuration-aggregators failed (rc=%s): %s"}' \
    "$rc" "$(json_escape "$names" | cut -c1-300)"
  exit 0
fi

# Control Tower names its aggregator with an `aws-controltower` prefix
# (canonically: aws-controltower-GuardrailsComplianceAggregator).
case " $names " in
  *aws-controltower*) found="true" ;;
  *) found="false" ;;
esac

printf '{"found":"%s","aggregators":"%s","detail":"ok"}' \
  "$found" "$(json_escape "$names")"
exit 0
