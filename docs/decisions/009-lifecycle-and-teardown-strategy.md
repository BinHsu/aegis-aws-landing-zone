# 009. Lifecycle and Teardown Strategy

## Status
Accepted

## Context
The account fabric is steady-state infrastructure. AWS Organizations, the OUs, the SCPs, AWS Identity Center, the Terraform state bucket, and the organization-wide IPAM are always-on by design — they are the foundation every account is built on, and tearing them down between sessions would mean re-bootstrapping the entire organization each time. The fabric's baseline cost is low (~$5/month) and stable, so there is no per-session teardown to run.

What the account fabric still owns are the *account-lifecycle* operations: closing accounts at the end of the project, and cleaning up a single account when its Terraform state has drifted from reality. Both are destructive at the account level, and the blast radius of any account-lifecycle teardown is the entire account. A badly designed teardown here is either too easy to trigger accidentally or insufficiently guarded; a well-designed one has clearly differentiated safety UX for each path.

This ADR defines the account-lifecycle teardown strategy for `aegis-aws-landing-zone`, including the deliberate rejection of AWS account closure as a routine cleanup mechanism and the deliberate introduction of friction into destructive operations.

## Decision

Two completely separate teardown scripts with strict UX safety. No shared flags, no shared entry points — a single typo on a flag must never escalate "clean one account" into "destroy my organization."

**`scripts/teardown/hard-teardown-landing-zone.sh` — one-time-project-lifetime path.** It decommissions the Control Tower landing zone and calls the AWS `CloseAccount` API for all member accounts. It requires three separate typed confirmations: a full sentence acknowledging the 90-day account closure rule, the management account ID (forcing the operator to switch windows and look it up), and a specific destruction phrase. It refuses to run in any CI environment regardless of approval gates, and can only be invoked from a local terminal. After the third confirmation, a final ten-second countdown provides one last cancellation opportunity. This script is run once, at the end of the project's life.

**`scripts/emergency/nuke-workload-account.sh` — drift-recovery path.** This wraps Gruntwork's open-source `cloud-nuke` tool as a targeted cleanup for a single workload account when that account's Terraform state has drifted from reality — for example, after a manual console change introduced a resource Terraform does not know about. It refuses to target the management, security, logarchive, or shared accounts; it can only target `aegis-staging`, `aegis-prod`, or a future sandbox account. It requires typed confirmation of the target account name and supports a dry-run mode by default.

**Cleanup operates at the resource layer, not the account layer.** AWS `CloseAccount` is explicitly rejected as a routine cleanup mechanism for three independent reasons, each of which would alone be disqualifying:

1. **90-day lockout.** Closed accounts enter a 90-day suspension period during which their email addresses cannot be reused. A workshop running on any regular cadence cannot wait 90 days between runs.
2. **10% / 30-day rolling close quota.** AWS Organizations enforces a rolling 10% / 30-day close quota with a minimum of 10 accounts, making repeated close cycles impossible for a six-account organization — closing all six exhausts the quota for the next 30 days.
3. **Control Tower meta-state drift.** Control Tower's enrollment state tracks member accounts by ID. Repeated close and re-create cycles create divergence between Control Tower's expected state and actual state, requiring operator intervention to reconcile.

These are AWS platform constraints, not implementation choices, and they make account closure the wrong primitive for routine cleanup. Account closure is reserved for end-of-project permanent decommissioning via `hard-teardown-landing-zone.sh`.

## Cost Model

The account fabric's cost is approximately five dollars per month: Control Tower baseline plus AWS Config recorder plus organizational CloudTrail (management events free, data events off for cost control) plus S3 log storage plus the IPAM advanced tier. It is steady-state — there is no per-session ephemeral cost to destroy, because the fabric runs no cost-incurring per-session resources.

The five-dollar baseline sits well below the ten-dollar-per-day budget alert ceiling documented in CLAUDE.md.

## Alternatives Considered

**Single teardown script with a `--hard` flag.** Rejected. Cognitive overlap between a drift-recovery cleanup and a full organization decommission is dangerous — a flag typo during a tired late-night session is exactly how accidents happen. Separating the scripts creates enough physical distance (different filename, different path, different tab-completion prefix) that conflation becomes impossible under normal workflows.

**Per-session account closure and re-creation.** Rejected — see the three AWS platform constraints above.

**Decommission Control Tower between sessions.** Rejected. Control Tower takes roughly thirty minutes to re-provision on each re-enrollment, the audit trail is polluted by repeated decommission-and-re-enrollment cycles, and the re-launch process is not currently automatable in a way that fits any regular cadence.

**Use AWS Budgets auto-shutoff as a teardown mechanism.** Rejected. AWS Budgets can send notifications and trigger Lambdas but cannot directly terminate resources, and Lambda-based auto-shutoff is a circuit breaker, not a deliberate teardown. Circuit breakers belong as a backstop, not as the primary mechanism.

## Consequences

Two operational paths to document. Users coming from `terraform destroy` directly must discover the wrappers, so the README and `scripts/teardown/README.md` prominently link both and explain when to use each.

Hard teardown is intentionally high-friction. An operator cannot decommission the landing zone from a remote session, from CI, or from a script that lacks a TTY. This is a deliberate trade-off: friction during a rare destructive operation is a feature, not a defect. The operator must be physically present at a terminal with full context, typing confirmations.

`cloud-nuke` is scoped exclusively to workload accounts and cannot touch the Control Tower baseline, the shared account, the security account, or the log archive account. This constraint is enforced in the script itself, not merely documented — the script refuses with a non-zero exit code if the target account name matches a protected list.

The cost model is predictable. The operator plans against a known ~$5/month baseline with no variable per-session component. The budget alert at ten dollars per day remains as a backstop but should never be triggered under normal use.
