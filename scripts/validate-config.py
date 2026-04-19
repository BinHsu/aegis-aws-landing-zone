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
    # See docs/decisions/018-multi-region-eks-design.md §2.
    errors: list[str] = []

    # Invariant 1: exactly one role: primary in top-level regions[]
    region_primaries = [r for r in config["regions"] if r.get("role") == "primary"]
    if len(region_primaries) != 1:
        errors.append(
            f"regions[] must have exactly one entry with role: primary "
            f"(found {len(region_primaries)})."
        )

    # EKS invariants — per environment
    governance_region_names = {r["name"] for r in config["regions"]}
    for env_name, env_cfg in config.get("eks", {}).items():
        if "regions" not in env_cfg:
            continue
        eks_regions = env_cfg["regions"]

        # Invariant 2: exactly one primary per env
        primaries = [r for r in eks_regions if r.get("role") == "primary"]
        if len(primaries) != 1:
            errors.append(
                f"eks.{env_name}.regions[] must have exactly one entry with "
                f"role: primary (found {len(primaries)})."
            )

        # Invariant 3: subset of top-level regions[]
        for r in eks_regions:
            if r["region"] not in governance_region_names:
                errors.append(
                    f"eks.{env_name}.regions[] contains region "
                    f"'{r['region']}' not in top-level regions[]. "
                    f"All eks regions must be a subset of the governance "
                    f"region footprint. Add '{r['region']}' to regions[] "
                    f"(with role + zones + ipam.pools entry) before "
                    f"declaring an EKS cluster there."
                )

        # Invariant 4: no duplicate regions within an env
        eks_region_names = [r["region"] for r in eks_regions]
        if len(eks_region_names) != len(set(eks_region_names)):
            duplicates = sorted(
                {n for n in eks_region_names if eks_region_names.count(n) > 1}
            )
            errors.append(
                f"eks.{env_name}.regions[] has duplicate region(s): "
                f"{duplicates}. Each region may appear at most once per env."
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
