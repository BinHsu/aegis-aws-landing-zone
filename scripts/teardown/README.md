# Teardown scripts

Two scripts, two different risk profiles. See [ADR-009](../../docs/decisions/009-lifecycle-and-teardown-strategy.md)
for the full strategy and rationale.

> **Scope note (ADR-033).** After the account-fabric descope this repository
> has **no cost-incurring per-session layers** — no EKS, no NAT, no workload
> compute. The old `soft-teardown-workload.sh` (per-session destroy of the
> `network` / `platform` / `workloads` layers) moved to the Platform-tier
> repository `aegis-platform` with the layers it tore down. What remains here
> is account-lifecycle teardown only: end-of-project decommission, and
> drift-recovery cleanup of a workload account.

## Decision tree

```
What do you want to destroy?
├── The entire project, permanently (project-end)            → hard-teardown-landing-zone.sh
└── Terraform state drifted from reality, reset one account  → ../emergency/nuke-workload-account.sh
```

## `hard-teardown-landing-zone.sh` — project end

**Destroys:** Management SCPs, shared IPAM + AFT, every account bootstrap
layer, the Control Tower landing zone. **Calls CloseAccount on all member
accounts** — they enter AWS's 90-day suspension period.

**Safety features (triple-confirmed):**
1. Full-sentence acknowledgement of the 90-day rule
2. Type the management account ID (forces operator to switch windows and look it up)
3. Type a specific destruction phrase
4. 10-second final countdown with `Ctrl-C` cancel

**Additional restrictions:**
- Refuses to run if any CI environment variable is set (`CI`, `GITHUB_ACTIONS`, `GITLAB_CI`, `JENKINS_URL`, `BUILDKITE`, `CIRCLECI`)
- Refuses to run without a real TTY on both stdin and stdout
- Requires running locally from the developer's terminal

**When to use:** Exactly once, when the project is genuinely over. This is not
a session-level teardown — it permanently suspends AWS accounts for 90 days.

**After running:** The management account itself cannot be closed via CLI.
Sign in as the root user via the AWS Console to close it manually.

## `../emergency/nuke-workload-account.sh` — drift recovery

**Destroys:** All AWS resources in a single workload account (staging, prod, or
future sandbox), bypassing Terraform state entirely. Wraps
[Gruntwork's cloud-nuke](https://github.com/gruntwork-io/cloud-nuke).

**Safety features:**
- Strict allowlist: **only** staging / prod / sandbox accounts. Refuses management / security / logarchive / shared.
- Dry-run by default (`--dry-run`); `--destroy` required for actual deletion
- Requires cloud-nuke binary installed locally (`brew install cloud-nuke`)
- Validates `AWS_PROFILE` matches target
- Requires typed confirmation of account name (destroy mode only)

**Usage:**

```bash
export AWS_PROFILE=aegis-staging-admin
aws sso login --sso-session aegis

# Always dry-run first:
./scripts/emergency/nuke-workload-account.sh staging

# After reviewing the dry-run output, actually destroy:
./scripts/emergency/nuke-workload-account.sh staging --destroy
```

**When to use:** When Terraform state has desynchronized from reality (e.g.
someone made changes via the AWS Console) and you need to reset the target
account before re-applying Terraform from scratch. Terraform state will be
invalid afterward — re-run `terraform init` and re-apply in each layer.

## Cost model

The account fabric's always-on baseline is ~$5/month (Control Tower + AWS
Config recorder + organizational CloudTrail + S3 log storage). There is no
per-session variable cost to tear down — the cost-incurring layers (EKS, NAT,
ALB) live in the Platform-tier repository and are torn down there.

| Action | Cost impact |
|--------|-------------|
| Steady state (no teardown) | ~$5/month account-fabric baseline |
| `hard-teardown-landing-zone.sh` | One-time; after completion, monthly cost drops to $0 |
