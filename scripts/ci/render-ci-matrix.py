#!/usr/bin/env python3
"""
render-ci-matrix.py — render a GitHub Actions matrix from the committed CI
layer manifest (config/ci-layers.yaml) joined with the deployment config
(config/landing-zone.yaml).

Issue #320: this replaces the account IDs that were hand-copied into the plan
and apply workflow matrices. The manifest is the single source of the layer
list + order; the account IDs come from config/landing-zone.yaml. A layer whose
account ID is empty is a hard error (fail-closed, ADR-019 posture) — the
pipeline scope is fixed, so a missing ID is a misconfiguration, not a reason to
silently drop a guardrail layer from the matrix.

Selections (mutually exclusive views of the same manifest):
  plan            all layers, order irrelevant — the PR plan matrix.
  apply-baseline  the auto-applied layers (everything WITHOUT a `gate`), in
                  manifest order.
  apply-scps      the SCP layer(s) marked `gate: scps` — routed to the
                  human-review apply path (issue #316).

Output: a JSON array of {env, account_id} objects on stdout, suitable for
  echo "matrix=$(... --select plan)" >> "$GITHUB_OUTPUT"
then consumed by a job as strategy.matrix.include via fromJSON().

Usage:
  render-ci-matrix.py --select plan|apply-baseline|apply-scps
                      [--layers config/ci-layers.yaml]
                      [--config config/landing-zone.yaml]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required (pip3 install pyyaml).", file=sys.stderr)
    sys.exit(1)

REPO_ROOT = Path(__file__).resolve().parents[2]


def load_yaml(path: Path) -> dict:
    if not path.exists():
        print(f"ERROR: {path} not found.", file=sys.stderr)
        sys.exit(1)
    with path.open() as f:
        return yaml.safe_load(f)


def render(layers_doc: dict, config: dict, select: str) -> list[dict]:
    accounts = config.get("accounts", {})
    rows: list[dict] = []
    errors: list[str] = []

    for layer in layers_doc["layers"]:
        env = layer["env"]
        account = layer["account"]
        gate = layer.get("gate")

        # Invariant: the account key is the first path segment of env. Keeps the
        # manifest self-consistent and lets the policy suite cross-check it.
        first_segment = env.split("/", 1)[0]
        if account != first_segment:
            errors.append(
                f"{env}: account '{account}' != env first segment '{first_segment}'"
            )
            continue

        if select == "apply-baseline" and gate is not None:
            continue
        if select == "apply-scps" and gate != "scps":
            continue
        # select == "plan": include every layer.

        acct = accounts.get(account)
        if acct is None:
            errors.append(f"{env}: account '{account}' absent from config accounts{{}}")
            continue
        account_id = str(acct.get("id", "")).strip()
        if not account_id:
            errors.append(
                f"{env}: accounts.{account}.id is empty in config/landing-zone.yaml — "
                f"populate it (the layer cannot be planned/applied without it)."
            )
            continue

        rows.append({"env": env, "account_id": account_id})

    if errors:
        print("ERROR: cannot render CI matrix:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)

    if not rows:
        print(f"ERROR: selection '{select}' produced an empty matrix.", file=sys.stderr)
        sys.exit(1)

    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--select",
        required=True,
        choices=["plan", "apply-baseline", "apply-scps"],
    )
    ap.add_argument("--layers", default=str(REPO_ROOT / "config" / "ci-layers.yaml"))
    ap.add_argument("--config", default=str(REPO_ROOT / "config" / "landing-zone.yaml"))
    args = ap.parse_args()

    layers_doc = load_yaml(Path(args.layers))
    config = load_yaml(Path(args.config))
    rows = render(layers_doc, config, args.select)

    # Compact JSON — this is consumed by fromJSON() in the workflow.
    print(json.dumps(rows, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
