# 009. Lifecycle and Teardown Strategy

## Status
Accepted

## Context
A lab landing zone will be spun up, torn down, and spun up again repeatedly over the project's lifetime. The per-session cost model, the per-session operational overhead, and the blast radius of any teardown operation are all downstream of how teardown is designed. A badly designed teardown is either too expensive to run frequently (discouraging use), too easy to trigger accidentally (dangerous), or both. A well-designed teardown has multiple paths, each with clearly differentiated safety UX, each targeting the right level of operation for its use case.

This ADR defines the teardown strategy for `aegis-aws-landing-zone`, including the deliberate rejection of AWS account closure as a per-session cleanup mechanism and the deliberate introduction of friction into destructive operations.

## Decision

Two completely separate teardown scripts with strict UX safety. No shared flags, no shared entry points — a single typo on a flag must never escalate "clean my workloads" into "destroy my organization." Plus one emergency cleanup wrapper for resource drift cases.

**`scripts/teardown/soft-teardown-workload.sh` — frequent-use path.** It destroys only Terraservices workload layers (`network`, `platform`, `workloads`) in a specified environment, leaving `bootstrap`, the shared account, the security account, the log archive account, and Control Tower itself untouched. Before running, it verifies that `stdin` is a TTY, that the current AWS profile matches the target account, and that the git working tree has no uncommitted changes. It requires the operator to type the environment name as confirmation — not "yes", not a key press, but the actual environment string. It is also exposed via a GitHub Actions `workflow_dispatch` workflow with a GitHub Environments approval gate, so CI/CD safety gates become portfolio-visible as an interview talking point.

**`scripts/teardown/hard-teardown-landing-zone.sh` — one-time-project-lifetime path.** It destroys all workload layers, decommissions the Control Tower landing zone, and calls the AWS `CloseAccount` API for all member accounts. It requires three separate typed confirmations: a full sentence acknowledging the 90-day account closure rule, the management account ID (forcing the operator to switch windows and look it up), and a specific destruction phrase. It refuses to run in any CI environment regardless of approval gates, and can only be invoked from a local terminal. After the third confirmation, a final ten-second countdown provides one last cancellation opportunity.

**`scripts/emergency/nuke-workload-account.sh` — emergency cleanup wrapper.** This wraps Gruntwork's open-source `cloud-nuke` tool as a targeted cleanup for a single workload account when Terraform state has drifted from reality — for example, after a manual console change introduced a resource Terraform does not know about. It refuses to target the management, security, logarchive, or shared accounts; it can only target `aegis-staging`, `aegis-prod`, or a future sandbox account. It requires typed confirmation of the target account name and supports a dry-run mode by default.

**Per-session cleanup operates at the resource layer, not the account layer.** AWS `CloseAccount` is explicitly rejected as a per-session mechanism for three independent reasons, each of which would alone be disqualifying:

1. **90-day lockout.** Closed accounts enter a 90-day suspension period during which their email addresses cannot be reused. A workshop running weekly cannot wait 90 days between runs.
2. **10% / 30-day rolling close quota.** AWS Organizations enforces a rolling 10% / 30-day close quota with a minimum of 10 accounts, making repeated close cycles impossible for a six-account organization — closing all six exhausts the quota for the next 30 days.
3. **Control Tower meta-state drift.** Control Tower's enrollment state tracks member accounts by ID. Repeated close and re-create cycles create divergence between Control Tower's expected state and actual state, requiring operator intervention to reconcile.

These are AWS platform constraints, not implementation choices, and they make account closure the wrong primitive for per-session cleanup. Account closure is reserved for end-of-project permanent decommissioning via `hard-teardown-landing-zone.sh`.

## Cost Model

**Persistent framework costs** are approximately five dollars per month: Control Tower baseline plus AWS Config recorder plus organizational CloudTrail (management events free, data events off for cost control) plus S3 log storage.

**Per-session ephemeral costs** run approximately one to two dollars per session for EKS control plane, NAT Gateways, and workload compute — destroyed at session end via `soft-teardown-workload.sh`.

**Total monthly budget** is expected to range nine to thirteen dollars under disciplined use, well below the ten-dollar-per-day budget alert ceiling documented in CLAUDE.md.

## Alternatives Considered

**Single teardown script with a `--hard` flag.** Rejected. Cognitive overlap between soft and hard modes is dangerous — a flag typo during a tired late-night session is exactly how accidents happen. Separating the scripts creates enough physical distance (different filename, different path, different tab-completion prefix) that conflation becomes impossible under normal workflows.

**Per-session account closure and re-creation.** Rejected — see the three AWS platform constraints above.

**Always-on EKS with no teardown.** Rejected. EKS control plane alone is approximately seventy-three dollars per month, and NAT Gateways add roughly thirty-three dollars per AZ per month. Leaving the full workload running between sessions exceeds the budget ceiling by an order of magnitude.

**Decommission Control Tower between sessions.** Rejected. Control Tower takes roughly thirty minutes to re-provision on each re-enrollment, the audit trail is polluted by repeated decommission-and-re-enrollment cycles, and the re-launch process is not currently automatable in a way that fits a weekly cadence.

**Use AWS Budgets auto-shutoff as the teardown mechanism.** Rejected. AWS Budgets can send notifications and trigger Lambdas but cannot directly terminate resources, and Lambda-based auto-shutoff is a circuit breaker, not a deliberate teardown. Circuit breakers belong as a backstop, not as the primary mechanism.

## Consequences

Two operational paths to document. Users coming from `terraform destroy` directly must discover the wrappers, so the README and `scripts/teardown/README.md` prominently link both and explain when to use each.

Hard teardown is intentionally high-friction. An operator cannot destroy the landing zone from a remote session, from CI, or from a script that lacks a TTY. This is a deliberate trade-off: friction during a rare destructive operation is a feature, not a defect. The operator must be physically present at a terminal with full context, typing confirmations.

Soft teardown via `workflow_dispatch` with an approval gate creates a portfolio-visible example of CI/CD safety controls, which is a common interview discussion point. It demonstrates understanding of why destructive CI/CD operations need approval gates rather than being a pure automation play.

`cloud-nuke` is scoped exclusively to workload accounts and cannot touch the Control Tower baseline, the shared account, the security account, or the log archive account. This constraint is enforced in the script itself, not merely documented — the script refuses with a non-zero exit code if the target account name matches a protected list.

The cost model is predictable. The operator can plan sessions against a known ~$5/month baseline plus ~$1-2/session variable cost, which fits comfortably under any reasonable lab budget. The budget alert at ten dollars per day remains as a backstop but should never be triggered under normal use.
