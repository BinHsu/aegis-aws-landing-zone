#!/usr/bin/env python3
"""
Validate config/landing-zone.yaml against config/schema.json.

Called by pre-commit hook on config changes. Exit 0 on valid, 1 on invalid.
"""

import json
import sys
from pathlib import Path


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    config_path = repo_root / "config" / "landing-zone.yaml"
    schema_path = repo_root / "config" / "schema.json"

    if not config_path.exists():
        print(f"ERROR: {config_path} does not exist.", file=sys.stderr)
        return 1

    if not schema_path.exists():
        print(f"ERROR: {schema_path} does not exist.", file=sys.stderr)
        return 1

    try:
        import yaml
    except ImportError:
        print("ERROR: PyYAML is required. Install: pip3 install pyyaml", file=sys.stderr)
        return 1

    try:
        import jsonschema
    except ImportError:
        print("ERROR: jsonschema is required. Install: pip3 install jsonschema", file=sys.stderr)
        return 1

    with config_path.open() as f:
        config = yaml.safe_load(f)

    with schema_path.open() as f:
        schema = json.load(f)

    try:
        jsonschema.validate(instance=config, schema=schema)
    except jsonschema.ValidationError as e:
        print(f"ERROR: config/landing-zone.yaml fails schema validation:", file=sys.stderr)
        print(f"  Path: {'.'.join(str(p) for p in e.absolute_path)}", file=sys.stderr)
        print(f"  Message: {e.message}", file=sys.stderr)
        return 1

    # Cross-field invariants not expressible in JSON Schema.
    errors: list[str] = []

    # Invariant: exactly one role: primary in regions[]. The region list also
    # feeds the IPAM regional pools (one pool per region) and the SCP
    # region-deny allow-list.
    region_primaries = [r for r in config["regions"] if r.get("role") == "primary"]
    if len(region_primaries) != 1:
        errors.append(
            f"regions[] must have exactly one entry with role: primary "
            f"(found {len(region_primaries)})."
        )

    if errors:
        print(
            "ERROR: config/landing-zone.yaml fails cross-field validation:",
            file=sys.stderr,
        )
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print("config/landing-zone.yaml: valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
