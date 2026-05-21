<!-- session-close-review: evidence entries reference runs that actually happened; no stale claims -->

# Evidence

This directory holds **proof artifacts from real runs** — committed, not
linked.

The principle: a claim ("the cold bootstrap is clean", "the SCP denies a
non-EU region as designed", "the state bucket survived a simulated delete")
is worth little on its own. The evidence is worth committing. A live link to
a console page or a CI run is *not* evidence — pages change, runs age out,
URLs rot. Capture the proof and check it in.

> **Scope note.** This repository owns the **account fabric** only. Evidence
> here is about the fabric: account bootstrap, SCP enforcement, OIDC federation,
> the state backend, IPAM allocation. Workload evidence (EKS bootstrap records,
> DR drill reports, multi-region failover tests, destroy-clean confirmations)
> is a platform concern and out of scope here.

## What belongs here

- **Bootstrap records** — `terraform plan` diffs and the verification outcome
  from a fresh apply of the account-fabric layers, plus the Control Tower
  enrollment walk-through outcome (Runbook 001).
- **SCP enforcement proof** — a denied API call in a non-governed region, or a
  denied IAM-user-creation attempt, showing the guardrail behaves as designed.
- **OIDC federation proof** — a CI run log showing `AssumeRoleWithWebIdentity`
  succeeding with the expected subject claim and short-lived credentials.
- **State-backend protection proof** — evidence that versioning, KMS
  encryption, and the org-scoped bucket policy behave as documented; a
  simulated-delete recovery transcript once the recovery runbook exists.
- **IPAM allocation proof** — a CIDR allocation from a RAM-shared pool, showing
  non-overlap enforcement at the API boundary.

## Naming convention

- A multi-file artifact (transcript + screenshots + logs) gets its own
  subdirectory: `NNN-<topic>/` with a short `README.md` inside.
- A single-file artifact: `<YYYY-MM-DD>-<topic>.md`.

Cross-reference the relevant ADR, runbook, or `docs/incidents.md` entry from
inside the artifact so a reader can trace claim → decision → proof.

## Anonymisation

Evidence is committed and public. It follows the same rule as the rest of the
repo (`CLAUDE.md` Security): AWS account IDs, Org/OU IDs, ARNs, and bucket
names are **metadata, not secrets** — safe to include. Static credentials
(access keys, tokens, private keys) must never appear; this project has none
by design. Scrub any screenshot or log that would otherwise leak one.
