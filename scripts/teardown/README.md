# Teardown scripts

Three scripts, three different risk profiles. Pick based on what you actually want to destroy. See [ADR-009](../../docs/decisions/009-lifecycle-and-teardown-strategy.md) for the full strategy and rationale.

## Decision tree

```
Did you create something you want to tear down?
├── Yes, workload layers in one environment (end-of-session)     → soft-teardown-workload.sh
├── Yes, the entire project (project-end)                        → hard-teardown-landing-zone.sh
└── Terraform state drifted from reality, need to reset account  → ../emergency/nuke-workload-account.sh
```

## `soft-teardown-workload.sh` — common case

**Destroys:** `workloads`, `platform`, `network` layers in one environment.
**Preserves:** `bootstrap` layer, shared services, all other accounts, Control Tower.

**Safety features:**
- Requires interactive TTY (no pipe, no CI)
- Requires clean git working tree
- Validates `AWS_PROFILE` matches target environment
- Verifies live AWS session matches `config/landing-zone.yaml` account ID
- Requires typed confirmation of the environment name

**Usage:**

```bash
export AWS_PROFILE=aegis-staging-admin
aws sso login --sso-session aegis
./scripts/teardown/soft-teardown-workload.sh staging
```

**When to use:** At the end of every session where you stood up EKS / NAT / workloads. Returns monthly cost from session-spike levels back to the ~$5 baseline.

**Expected duration:** 10–25 minutes per environment. The NAT Gateway destroys in under a minute, but the VPC itself (IPAM-managed) waits for IPAM's asynchronous CIDR-release detection, which is typically 10–20 minutes. See ADR-004 Consequences for rationale.

## `hard-teardown-landing-zone.sh` — project end

**Destroys:** All workload layers in all environments, management SCPs, shared IPAM, all bootstrap layers, Control Tower landing zone. **Calls CloseAccount on all member accounts** — they enter AWS's 90-day suspension period.

**Safety features (triple-confirmed):**
1. Full-sentence acknowledgement of the 90-day rule
2. Type the management account ID (forces operator to switch windows and look it up)
3. Type a specific destruction phrase
4. 10-second final countdown with `Ctrl-C` cancel

**Additional restrictions:**
- Refuses to run if any CI environment variable is set (`CI`, `GITHUB_ACTIONS`, `GITLAB_CI`, `JENKINS_URL`, `BUILDKITE`, `CIRCLECI`)
- Refuses to run without a real TTY on both stdin and stdout
- Requires running locally from the developer's terminal

**When to use:** Exactly once, when the project is genuinely over. This is not a session-level teardown — it permanently suspends AWS accounts for 90 days.

**After running:** The management account itself cannot be closed via CLI. Sign in as the root user via the AWS Console to close it manually.

## `../emergency/nuke-workload-account.sh` — drift recovery

**Destroys:** All AWS resources in a single workload account (staging, prod, or future sandbox), bypassing Terraform state entirely. Wraps [Gruntwork's cloud-nuke](https://github.com/gruntwork-io/cloud-nuke).

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

**When to use:** When Terraform state has desynchronized from reality (e.g., someone made changes via the AWS Console) and you need to reset the target account before re-applying Terraform from scratch. Terraform state will be invalid afterward — re-run `terraform init` and re-apply in each layer.

## Cost model

| Action | Cost impact |
|--------|-------------|
| Never run teardown | NAT ($32/month) + EKS ($73/month) accumulate indefinitely |
| `soft-teardown-workload.sh` at session end | Session cost ~$1-2 one-time; baseline ~$5/month retained |
| `hard-teardown-landing-zone.sh` | One-time; after completion, monthly cost drops to $0 |

Per ADR-009: teardown discipline is the difference between a $10/month lab and a $150/month forgotten-infrastructure bill.
