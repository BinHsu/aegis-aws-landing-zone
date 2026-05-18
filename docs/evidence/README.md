<!-- session-close-review: evidence entries reference drills/applies that actually happened; no stale claims -->

# Evidence

This directory holds **proof artifacts from real runs** — committed, not
linked.

The principle: a claim ("DR recovery takes ~11 minutes", "the cold apply is
clean", "the surviving region served every request") is worth little on its
own. The evidence is worth committing. A live link to a dashboard or a CI run
is *not* evidence — dashboards reset, runs age out, URLs rot. Capture the
proof and check it in.

## What belongs here

- **DR drill reports** — FIS experiment runs (ADR-020, Runbook 005): the
  phase-by-phase timeline, measured RTO/RPO, the dashboard screenshot showing
  metrics drop → rebuild → recover.
- **Cold-apply records** — `terraform plan` diffs and the verification
  checklist outcome from a fresh apply of the workload layers
  (Runbook 003).
- **Multi-region failover tests** — health-probe logs proving the surviving
  region served traffic while the other was down.
- **Teardown-clean confirmations** — proof a session ended with no orphaned
  EKS cluster, NAT Gateway, or ENI.

## Naming convention

- A multi-file artifact (timeline + screenshots + logs) gets its own
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
