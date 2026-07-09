#!/usr/bin/env python3
"""
policy_test.py — policy-as-code gate for the account-fabric guardrails (#321).

WHY THIS EXISTS
  Before this suite, the security guardrails in epic #312 were verified only by
  `terraform plan` + Checkov + human review. Checkov tests generic IaC hygiene;
  it does NOT know that "every gh-tf-* CI role MUST carry the Aegis permissions
  boundary" (#313) or that "the CI matrix MUST match config/landing-zone.yaml"
  (#320). This suite encodes those repo-specific invariants so a future PR that
  loosens one fails CI instead of merging silently.

WHY PYTHON (not conftest/OPA or `terraform test`)
  The repo's config-test toolchain is already Python: scripts/validate-config.py
  validates config/landing-zone.yaml against config/schema.json (wired into
  .pre-commit-config.yaml). This suite extends that pattern — no new binary, no
  Rego, no AWS credentials, no provider download. It reads committed .tf/.yaml
  as text/structured data and asserts invariants in-process, so it runs in well
  under a second and adds negligible time to PR CI. `terraform test` would need
  provider init per layer (slow, and 1.14.x mock-provider plumbing across 9
  layers); conftest/OPA would add a binary + a second policy language for the
  same assertions. Justified in ADR-022.

WHAT IT CHECKS  (each is a regression guard for a specific epic finding)
  P1  Every IAM role named gh-tf-* declares
      `permissions_boundary = aws_iam_policy.ci_boundary.arn`.            (#313)
  P2  The CI permissions-boundary document keeps its escalation deny-floor
      (DenyStripAnyBoundary / DenyPutNonAegisBoundary /
      DenyCreateWithoutAegisBoundary).                                    (#313)
  P3  The org-root SCP layer keeps the core Deny SCPs + their root
      attachments (deny-root-user-actions, deny-iam-user-creation).       (SCP)
  P4  Every backend.tf points at the state bucket derived from config
      (`<org>-terraform-state-<shared_id>`) in the primary region.        (#320)
  P5  config/ci-layers.yaml covers exactly the account-fabric layer dirs on
      disk, and each layer's `account` == its env's first path segment.   (#320)
  P6  config/landing-zone.yaml validates against schema.json + exactly one
      primary region (delegates to validate-config.py's contract).        (config)
  P7  The shared state bucket policy denies non-TLS access
      (DenyInsecureTransport).                                            (state)

Exit 0 = all pass; 1 = one or more fail (prints every failure, does not stop at
the first). Runs against config/landing-zone.yaml if present, else falls back to
config/landing-zone.example.yaml so it is runnable on a fresh clone / locally.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required (pip3 install pyyaml).", file=sys.stderr)
    sys.exit(1)

REPO_ROOT = Path(__file__).resolve().parents[2]
TF_ROOT = REPO_ROOT / "terraform" / "environments"

# Roles intentionally NOT carrying the CI boundary (documented exemptions).
# Break-glass is the in-account repair path for a corrupted boundary (ADR-020
# D3); a bounded break-glass could not repair the boundary. It is matched by
# name prefix, so this suite keys the P1 invariant on the gh-tf-* family only.
BOUNDED_ROLE_NAME_PREFIX = "gh-tf-"
EXPECTED_BOUNDARY = "aws_iam_policy.ci_boundary.arn"


class Results:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.checks = 0

    def check(self, ok: bool, msg: str) -> None:
        self.checks += 1
        if not ok:
            self.failures.append(msg)


def iter_resource_blocks(text: str, resource_type: str):
    """Yield (name_label, block_text) for each `resource "<type>" "<label>"`.

    Brace-depth aware so it survives nested blocks (assume_role_policy,
    condition, etc.). Good enough for the well-formatted HCL in this repo; the
    invariants it feeds are coarse presence/consistency checks, not a parser.
    """
    pat = re.compile(
        r'resource\s+"' + re.escape(resource_type) + r'"\s+"([^"]+)"\s*\{'
    )
    for m in pat.finditer(text):
        label = m.group(1)
        depth = 1
        i = m.end()
        while i < len(text) and depth > 0:
            c = text[i]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            i += 1
        yield label, text[m.end() : i - 1]


def load_config() -> tuple[dict, Path, bool]:
    real = REPO_ROOT / "config" / "landing-zone.yaml"
    example = REPO_ROOT / "config" / "landing-zone.example.yaml"
    is_real = real.exists()
    path = real if is_real else example
    with path.open() as f:
        return yaml.safe_load(f), path, is_real


# --- P1: gh-tf-* roles carry the CI permissions boundary --------------------
def p1_boundary_on_ci_roles(r: Results) -> None:
    role_files = sorted(TF_ROOT.rglob("*.tf"))
    seen_ci_roles = 0
    for f in role_files:
        text = f.read_text()
        for label, block in iter_resource_blocks(text, "aws_iam_role"):
            name_m = re.search(r'name\s*=\s*"([^"]+)"', block)
            if not name_m:
                continue
            role_name = name_m.group(1)
            if not role_name.startswith(BOUNDED_ROLE_NAME_PREFIX):
                continue
            seen_ci_roles += 1
            rel = f.relative_to(REPO_ROOT)
            pb = re.search(r"permissions_boundary\s*=\s*([^\n]+)", block)
            r.check(
                pb is not None and EXPECTED_BOUNDARY in pb.group(1),
                f"P1: role '{role_name}' in {rel} must set "
                f"permissions_boundary = {EXPECTED_BOUNDARY} (#313).",
            )
    # Guard against the check silently passing because the glob found nothing.
    r.check(
        seen_ci_roles >= 3,
        f"P1: expected >=3 gh-tf-* roles, found {seen_ci_roles} — "
        "the role discovery glob may be broken.",
    )


# --- P2: CI boundary keeps its escalation deny-floor ------------------------
def p2_boundary_deny_floor(r: Results) -> None:
    required = [
        "DenyStripAnyBoundary",
        "DenyPutNonAegisBoundary",
        "DenyCreateWithoutAegisBoundary",
    ]
    files = sorted(TF_ROOT.rglob("ci-permissions-boundary.tf"))
    r.check(len(files) >= 1, "P2: no ci-permissions-boundary.tf found (#313).")
    for f in files:
        text = f.read_text()
        rel = f.relative_to(REPO_ROOT)
        for sid in required:
            r.check(sid in text, f"P2: {rel} missing deny-floor Sid '{sid}' (#313).")


# --- P3: org-root SCPs present + attached to root ---------------------------
def p3_core_scps(r: Results) -> None:
    scp_main = TF_ROOT / "management" / "scps" / "main.tf"
    r.check(scp_main.exists(), "P3: management/scps/main.tf missing.")
    if not scp_main.exists():
        return
    text = scp_main.read_text()
    for policy_name in ["deny-root-user-actions", "deny-iam-user-creation"]:
        r.check(policy_name in text, f"P3: SCP '{policy_name}' missing from scps/main.tf.")
    attachments = list(
        iter_resource_blocks(text, "aws_organizations_policy_attachment")
    )
    root_attached = [
        lbl for lbl, blk in attachments if "local.root_id" in blk
    ]
    r.check(
        len(root_attached) >= 2,
        f"P3: expected >=2 SCP attachments to org root, found {len(root_attached)}.",
    )


# --- P4: backend buckets derive from config ---------------------------------
def p4_backend_consistency(r: Results, config: dict) -> None:
    org = config["organization"]["name"]
    shared_id = str(config["accounts"]["shared"]["id"]).strip()
    primary = next(
        (x["name"] for x in config["regions"] if x.get("role") == "primary"), None
    )
    expected_bucket = f"{org}-terraform-state-{shared_id}"
    backends = sorted(TF_ROOT.rglob("backend.tf"))
    r.check(len(backends) >= 9, f"P4: expected >=9 backend.tf, found {len(backends)}.")
    for f in backends:
        text = f.read_text()
        rel = f.relative_to(REPO_ROOT)
        bkt = re.search(r'bucket\s*=\s*"([^"]+)"', text)
        reg = re.search(r'region\s*=\s*"([^"]+)"', text)
        r.check(
            bkt is not None and bkt.group(1) == expected_bucket,
            f"P4: {rel} bucket '{bkt.group(1) if bkt else None}' != "
            f"'{expected_bucket}' derived from config (#320).",
        )
        r.check(
            reg is not None and reg.group(1) == primary,
            f"P4: {rel} region '{reg.group(1) if reg else None}' != "
            f"primary region '{primary}' (#320).",
        )


# --- P5: ci-layers.yaml matches on-disk layers ------------------------------
def p5_layer_manifest(r: Results) -> None:
    manifest_path = REPO_ROOT / "config" / "ci-layers.yaml"
    r.check(manifest_path.exists(), "P5: config/ci-layers.yaml missing (#320).")
    if not manifest_path.exists():
        return
    with manifest_path.open() as fh:
        manifest = yaml.safe_load(fh)
    manifest_envs = set()
    for layer in manifest["layers"]:
        env = layer["env"]
        manifest_envs.add(env)
        first = env.split("/", 1)[0]
        r.check(
            layer["account"] == first,
            f"P5: manifest layer '{env}' account '{layer['account']}' != "
            f"first path segment '{first}'.",
        )
        r.check(
            (TF_ROOT / env).is_dir(),
            f"P5: manifest layer '{env}' has no terraform/environments/{env}/ dir.",
        )
    # Every account-fabric layer dir on disk must be in the manifest. The
    # account-fabric layers are the leaf dirs holding a backend.tf, minus AFT
    # (vendor module, not driven by this pipeline — see checkov skip_path).
    disk_layers = {
        str(f.parent.relative_to(TF_ROOT))
        for f in TF_ROOT.rglob("backend.tf")
    }
    disk_layers.discard("shared/aft")
    missing = disk_layers - manifest_envs
    r.check(
        not missing,
        f"P5: layer dir(s) on disk not in config/ci-layers.yaml: {sorted(missing)} "
        "— add them to the manifest or they escape the CI matrix (#320).",
    )


# --- P6: config validates against schema ------------------------------------
def p6_config_schema(r: Results, config: dict, config_path: Path) -> None:
    schema_path = REPO_ROOT / "config" / "schema.json"
    try:
        import jsonschema
    except ImportError:
        r.check(False, "P6: jsonschema not installed (pip3 install jsonschema).")
        return
    schema = json.loads(schema_path.read_text())
    try:
        jsonschema.validate(instance=config, schema=schema)
        schema_ok = True
    except jsonschema.ValidationError as e:
        schema_ok = False
        r.check(False, f"P6: {config_path.name} fails schema: {e.message} at "
                       f"{'.'.join(str(p) for p in e.absolute_path)}")
    if schema_ok:
        primaries = [x for x in config["regions"] if x.get("role") == "primary"]
        r.check(
            len(primaries) == 1,
            f"P6: regions[] must have exactly one role: primary (found {len(primaries)}).",
        )


# --- P7: state bucket denies non-TLS ----------------------------------------
def p7_state_bucket_tls(r: Results) -> None:
    main_tf = TF_ROOT / "shared" / "bootstrap" / "main.tf"
    r.check(main_tf.exists(), "P7: shared/bootstrap/main.tf missing.")
    if not main_tf.exists():
        return
    text = main_tf.read_text()
    r.check(
        "aws_s3_bucket_policy" in text and "DenyInsecureTransport" in text,
        "P7: state bucket policy must keep a DenyInsecureTransport (TLS-only) "
        "statement (#314/#317).",
    )


def main() -> int:
    config, config_path, is_real = load_config()
    r = Results()
    p1_boundary_on_ci_roles(r)
    p2_boundary_deny_floor(r)
    p3_core_scps(r)
    if is_real:
        # Backend↔config consistency is only meaningful against the real
        # deployment config. The committed example.yaml carries placeholder
        # account IDs, so comparing it to the (real) backend bucket would be a
        # false positive. CI writes the real config from the secret, so P4
        # runs there — which is where drift matters.
        p4_backend_consistency(r, config)
    else:
        print("policy_test: P4 (backend↔config) skipped — example config "
              "(placeholders); runs in CI against the real config.")
    p5_layer_manifest(r)
    p6_config_schema(r, config, config_path)
    p7_state_bucket_tls(r)

    print(f"policy_test: config source = {config_path.name}")
    if r.failures:
        print(f"policy_test: FAIL ({len(r.failures)}/{r.checks} checks failed)\n",
              file=sys.stderr)
        for msg in r.failures:
            print(f"  ✗ {msg}", file=sys.stderr)
        return 1
    print(f"policy_test: PASS ({r.checks} checks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
