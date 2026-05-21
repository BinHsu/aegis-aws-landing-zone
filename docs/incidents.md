<!-- session-close-review: new incidents from this session; count matches README + interview-notes -->
# Incidents

A running postmortem log of every non-trivial failure during this project's deployment. Each entry is written after the fact, with the benefit of hindsight, and follows a consistent postmortem format so they are scannable.

**This file is append-only.** New incidents are added in chronological order. Existing entries are only edited to correct factual errors — never to soften the story after the fact.

A repository with no commit-history mistakes is either trivial or pretending. The incidents below are neither.

## Severity guide

| Severity | Meaning |
|----------|---------|
| **S1** | Production outage, data loss risk, or security breach |
| **S2** | Critical infrastructure unusable; recovery required within a known grace window |
| **S3** | Operator-blocking; state or config recovery needed; no data risk |
| **S4** | Operator inconvenience, workaround available |

---

## Incident 1 — KMS key policy insufficient at Control Tower launch

**Date**: 2026-04-12 (Phase 0, runbook §4)
**Severity**: S2 (initial landing zone deployment blocked)
**Duration**: ~30 min debugging + one Control Tower retry cycle

### Symptom

Control Tower landing zone enrollment failed mid-apply:

> Error: AWS Control Tower failed to deploy stack(s).
> CloudTrail baseline stack: Insufficient permissions to access S3 bucket `aws-controltower-cloudtrail-logs-*` or KMS key `arn:aws:kms:eu-central-1:186052668286:key/...`

CloudFormation rolled back. The rollback itself stuck on a CloudWatch Log Group CloudFormation could not delete under its rollback permissions.

### Root cause

The Control Tower setup wizard generates a default KMS key policy that includes only the management account root. Control Tower's CloudTrail baseline StackSet and AWS Config recorder run *in member accounts* (logarchive, security) and require the following on the key:

- `cloudtrail.amazonaws.com` service principal
- `config.amazonaws.com` service principal
- Cross-account Decrypt for logarchive (`118907880354`) and security (`763879260536`)

The wizard-generated policy had none of these. Fine for the management account's own operations; fatal for Control Tower's multi-account baseline.

### Detection

CloudFormation event log. The root error was nested several stacks deep; the `AccessDenied on KMS key <arn>` line pinpointed the cause.

### Resolution

1. Applied a v2 KMS key policy manually to the existing key, adding both service principals and cross-account Decrypt. Full JSON template in runbook §4.4.3.
2. Manually deleted the rollback-stuck CloudFormation stack via the CloudFormation console.
3. Manually deleted the orphaned CloudWatch Log Group (CloudFormation could not clean it up under rollback permissions).
4. Pressed "Retry" in the Control Tower dashboard. Successful on second attempt.

### Prevention

Never accept the Control Tower wizard's default KMS policy. Always customize *before* pressing Enable. Runbook §4.4.3 now contains the v2 policy as a drop-in template.

### Lessons

- AWS console wizards optimize for the simplest case, not the right case. Read every "default" option.
- CloudFormation rollback failures can orphan resources. CloudWatch Log Groups in particular do not auto-clean.
- KMS key policies are the primary authorization mechanism for keys. IAM policies in other accounts cannot bypass them.

---

## Incident 2 — IAM account alias globally unique collision

**Date**: 2026-04-12 (Phase 1, PR #72655ab)
**Severity**: S3 (Terraform apply blocked)
**Duration**: ~10 min

### Symptom

```
aws_iam_account_alias.this creation failed:
EntityAlreadyExists: The account alias aegis-prod already exists.
```

But:

```
$ aws iam list-account-aliases
{"AccountAliases": []}
```

Error said the alias existed; the target account said it didn't. Apparent contradiction.

### Root cause

IAM account aliases are **globally unique across all AWS customers worldwide**, not scoped to an organization or account. `aegis-prod` was already in use by an unrelated AWS customer somewhere. The `list-account-aliases` API returns aliases *in this account*, which is why the error looked contradictory.

### Detection

`aws iam create-account-alias` reproduced the collision. A targeted search of AWS documentation found exactly one sentence confirming global uniqueness.

### Resolution

Prefixed all aliases with the org identifier: `binhsu-aegis-*`. Updated `main.tf` in every bootstrap layer and reapplied.

### Prevention

Always use a domain-scoped or org-scoped prefix from the start. Raw short names (`aegis-prod`, `staging`, `management`) are likely to collide. A ~7+ character prefix unique to the project makes collision effectively impossible.

Runbook troubleshooting now documents this.

### Lessons

- "Account-scoped" is not always what the API name implies. Verify uniqueness scope in the service docs.
- `list-account-aliases` returning empty is not proof the alias is available — only that it's not *here*.

---

## Incident 3 — RAM cross-org sharing requires explicit enablement and correct apply order

**Date**: 2026-04-13 (Phase 3a, PRs #8 and #9)
**Severity**: S3 (shared/ipam apply blocked twice)
**Duration**: ~20 min across two apply cycles

### Symptom

First failed apply:

```
Error: creating RAM Principal Association: OperationNotPermittedException:
The resource you are attempting to share can only be shared within your
AWS Organization. ... or that onboarding process is still in progress.
```

After adding `aws_ram_sharing_with_organization`, second apply still failed with the same error — because CI ran `shared/ipam` *before* `management/bootstrap` in the matrix.

### Root cause

Two compounding issues:

1. **AWS Organizations support in RAM is an opt-in feature, disabled by default.** Until enabled via `aws_ram_sharing_with_organization` (or `aws ram enable-sharing-with-aws-organization`), any cross-org RAM share fails. Control Tower does not enable this automatically.
2. **Terraform apply matrix order was wrong.** Even after the enablement resource was added to `management/bootstrap`, the CI matrix ran `shared/ipam` first — so RAM was still disabled when IPAM tried to share its pools.

### Detection

Error message was clear on both attempts. The second failure required reading the matrix to understand *why* PR #8's fix hadn't worked.

### Resolution

1. PR #8: added `aws_ram_sharing_with_organization.main` to `management/bootstrap`.
2. PR #9: reordered `.github/workflows/terraform-apply.yml` matrix so foundation layers apply before consumers:
   ```
   1. management/bootstrap  (enables RAM sharing)
   2. shared/bootstrap
   3. shared/ipam           (consumes RAM sharing)
   4. staging/bootstrap
   5. management/scps       (last — SCPs could lock out operations)
   ```
3. Inline rationale comments were added to the workflow so future readers see *why*, not just *what*.

### Prevention

- Any cross-account capability that depends on org-level opt-in features must be validated against the apply matrix order at PR review time.
- When a new Terraservices layer is added, its matrix position must be justified: foundation layers first, workload layers next, SCPs last.
- Runbook troubleshooting now documents the RAM-enablement requirement.

### Lessons

- CI apply order matters for multi-layer Terraservices. Dependencies between layers across accounts are invisible to Terraform (it plans each layer independently).
- When debugging multi-layer Terraform, *reading the apply matrix* is the first diagnostic step. Resource A in layer X depending on resource B in layer Y means layer Y must apply first.

---

## Incident 4 — Control Tower UI stale after landing zone update

**Date**: 2026-04-12 (Phase 0, runbook §4.11)
**Severity**: S4 (operator inconvenience; no functional impact)
**Duration**: ~10 min of confusion

### Symptom

After running "Modify settings" → "Update landing zone" to clear residual drift, the Control Tower **Organization → Create account** page continued to display the pre-update drift error. Repeated clicks on "Retry" produced the same error. The landing zone *was* updated — API showed `driftStatus: IN_SYNC` — but the UI said otherwise.

### Root cause

Control Tower's console UI caches state aggressively and does not auto-refresh after an async landing zone operation. The browser's view was several minutes behind the actual resource state.

### Detection

API reported `IN_SYNC` while UI still showed drift warning. The API was trustworthy; the UI was not.

### Resolution

Navigated back to the Organization page, hard-refreshed the browser, re-entered the Create account flow. No error this time.

Second fallback (not needed here, but documented): launch Account Factory directly from Service Catalog, bypassing the Control Tower wrapper UI entirely.

### Prevention

Whenever a Control Tower async operation completes, hard-refresh the browser before retrying dependent actions. If the UI still disagrees with API state, trust the API.

### Lessons

- AWS console UIs are eventually-consistent. They are thin clients over the API, cached more aggressively than most operators assume.
- Not every failure is a backend bug. Some are purely UI cache staleness.
- Have a fallback path (Service Catalog direct) when the wrapper UI is stuck.

---

## Incident 5 — Cross-account `kms:Decrypt` denied with the `aws/s3` default key

**Date**: 2026-04-13 (Phase 3b, PR #25 Draft)
**Severity**: S3 (cross-account state read blocked a consuming layer's apply)
**Duration**: ~20 min to understand and design the fix

### Symptom

A consuming layer in the staging account used `data "terraform_remote_state" "shared_ipam"` to read IPAM pool IDs from `shared/ipam`. Plan failed:

```
Error: Unable to access object "shared/ipam/terraform.tfstate" in S3 bucket:
AccessDenied: User arn:aws:sts::251774439261:... is not authorized to
perform: kms:Decrypt on the resource associated with this ciphertext
because the resource does not exist in this Region, no resource-based
policies allow access, or a resource-based policy explicitly denies access
```

### Root cause

The state bucket was configured with `sse_algorithm = "aws:kms"` *without* specifying a `kms_master_key_id`, which defaults to the `aws/s3` AWS-managed KMS key. AWS-managed keys are **account-scoped**: their key policies allow only the owning account. Cross-account principals cannot be granted access via IAM policies in their own accounts — the key policy is the primary authorization mechanism for KMS, and AWS-managed keys' policies cannot be modified.

Staging role could not decrypt state written by shared role. The S3 bucket policy granted cross-account access, but the kms:Decrypt check happens independently and fails separately.

### Detection

Error named kms:Decrypt explicitly. Behavior pattern confirmed: same-account reads worked, cross-account failed.

### Resolution

1. Created a customer-managed KMS key (CMK) in shared account with a key policy granting `kms:Decrypt` and `kms:GenerateDataKey*` to any principal in the organization via the `aws:PrincipalOrgID` condition.
2. Updated the bucket's default encryption to reference the CMK's ARN.
3. Re-encrypted existing state files via `aws s3 cp s3://bucket/ s3://bucket/ --recursive --sse aws:kms --sse-kms-key-id <arn>` where possible. Files owned by other accounts (written by the management, staging, prod roles) would re-encrypt on their next apply.

### Prevention

Use customer-managed keys for any encryption where the intended consumer is not the bucket-owning account. Never use `sse_algorithm = "aws:kms"` *without* `kms_master_key_id` when cross-account access is planned.

Runbook and ADR-003 now document this.

### Lessons

- AWS-managed keys are account-local. The `aws:kms` setting looks generic but quietly defaults to an account-scoped key.
- Bucket policy and KMS key policy are *independent* authorization layers. Granting cross-account S3 access without granting cross-account KMS access produces a confusing asymmetry.

---

## Incident 6 — State bucket CMK scheduled for deletion by CI apply

**Date**: 2026-04-13 (Phase 3b, during PR #27 merge)
**Severity**: S2 (state bucket unusable; recovery required within deletion grace window)
**Duration**: ~15 min detect + recover

### Symptom

1. PR #27 (ECR repository in staging/bootstrap) merged.
2. `terraform-apply` workflow ran on main for all environments in the matrix.
3. `shared/bootstrap` apply *destroyed* the KMS CMK. KMS moved to "pending deletion" state.
4. `shared/ipam` apply then failed:
   ```
   KMS.KMSInvalidStateException: arn:aws:kms:...:key/828a9c68... is pending deletion.
   ```
5. Any operation on state files encrypted with that CMK began failing with the same error.

### Root cause

The CMK was introduced in PR #25 (staging VPC + NAT, kept in Draft to avoid NAT cost). The CMK code lived only on the PR #25 branch, not on main. However, the CMK itself *had been applied locally* to AWS (to unblock cross-account state-read testing from a consuming layer).

Result: main-branch `shared/bootstrap/main.tf` did not know about the CMK, but the live Terraform state did. When CI on the PR #27 merge ran `terraform apply` against `shared/bootstrap`, it saw CMK resources in state that were absent from main-branch code — and destroyed them.

AWS KMS never deletes keys immediately. They enter a 7-to-30-day "pending deletion" state during which they are unusable. Any data encrypted with the key becomes unreadable until the key is restored.

### Detection

Immediate. The next CI matrix step (shared/ipam apply) failed with `KMSInvalidStateException` naming the specific key ARN. The symptom appeared within one minute of PR #27 merging.

### Resolution

Executed in this exact order:

1. `aws kms cancel-key-deletion --key-id <arn>` — pulled the key back from the deletion queue.
2. `aws kms enable-key --key-id <arn>` — returned the key to the `Enabled` state (cancel-key-deletion alone leaves it `Disabled`).
3. `terraform force-unlock <lock-id>` — cleared the stale S3 state lock left by the failed CI run.
4. `terraform import aws_kms_key.terraform_state <arn>` — restored the key to Terraform state.
5. `terraform apply` — reconciled the alias (which had been fully deleted, not just scheduled) and the bucket's encryption configuration.

Total recovery: ~15 minutes. No data loss because AWS KMS's deletion grace window protected us.

### Prevention

- **Never apply Terraform locally from an unmerged branch for long-lived infrastructure.** Local applies create divergence between main-branch code and live state that CI will "correct" by destroying the off-main resources.
- **If a local apply is unavoidable** (e.g., breaking a bootstrap chicken-and-egg), land the code on `main` immediately after applying, before any other PR triggers the apply workflow.
- **Configure KMS deletion windows at the maximum** (30 days) to maximize recovery margin when this happens.
- **Future work:** consider an IAM boundary that removes `kms:ScheduleKeyDeletion` permission from CI roles for this specific key.

Runbook now documents the full recovery sequence.

### Lessons

- Terraform state is the source of truth for "what CI will do next." Any drift between state and main-branch code is a time bomb.
- The CI apply workflow is doing exactly what it's designed to do — reconcile state to code. The protection is on *what state* it reconciles against, not on the workflow itself.
- KMS's deletion grace window is a feature, not a flaw. The 7-day minimum gives enough time to detect and recover from this class of mistake — if the operator is paying attention.

---

## Incident 7 — IPAM delegated admin not configured for cross-account VPC allocation

**Date**: 2026-04-13 (Phase 3b, PR #25 through PR #33)
**Severity**: S3 (cross-account VPC allocation blocked; fix required three separate PRs and a destroy-recreate of IPAM)
**Duration**: ~90 min total across multiple failed apply cycles

### Symptom

After PR #25 merged and the apply workflow ran, a VPC-creating layer in the staging account failed at VPC creation:

```
Error: creating EC2 VPC: UnsupportedOperation: The operation
AllocateIpamPoolCidr is not supported. Account 251774439261 is not
monitored by IPAM ipam-02b647bff9b858621.
```

`shared/ipam` had already been applied, the RAM share with the organization was in place, and `staging` could see the pool via `aws ec2 describe-ipam-pools`. The VPC allocation call was still refused.

### Root cause

RAM sharing and IPAM monitoring are **independent concepts**, despite both being cross-account features:

- **RAM sharing** (`aws_ram_resource_share`): lets member accounts *see and consume* the IPAM pool in Terraform plans and describe-ipam-pools calls.
- **IPAM monitoring**: a separate service-level relationship between the IPAM instance and the accounts whose VPC allocations it tracks. Required for `AllocateIpamPoolCidr` to succeed.

When the IPAM instance is hosted in a member account (this project: `aegis-shared` per ADR-004 Mode B), IPAM monitoring requires **AWS Organizations integration**, which means delegating IPAM admin from the management account to the IPAM-hosting account.

Without delegation, IPAM only monitors the account it lives in. RAM-shared pools look usable via describe APIs but fail on actual allocation.

### Detection

Error message named the specific IPAM ID and the specific monitored-account gap. One of the more self-explanatory AWS errors.

### Resolution (three layers, in order)

This incident was not a single fix — the problem had three independent causes, each surfaced only after the previous one was resolved. The final working setup requires all four of the following:

1. **RAM sharing with org enabled** (already in place from earlier work) — `aws_ram_sharing_with_organization.main` in `management/bootstrap`. Lets pools be RAM-shareable.
2. **Organizations trusted service access for IPAM** — `aws organizations enable-aws-service-access --service-principal ipam.amazonaws.com`. One-time CLI, idempotent. The AWS Terraform provider does not expose this as a standalone resource; managing it via `aws_organizations_organization` would conflict with Control Tower's ownership.
3. **Delegated administrator for IPAM** — `aws_organizations_delegated_administrator` resource for `ipam.amazonaws.com` pointing at shared. Requires step 2 as prerequisite, otherwise fails with `ConstraintViolationException: You must enable service access before you delegate an administrator`.
4. **IPAM org admin enablement (IPAM-specific API)** — `aws ec2 enable-ipam-organization-admin-account --delegated-admin-account-id <shared>`. This is a DIFFERENT API from step 3. Generic org delegation does not automatically enable IPAM's org integration — IPAM has its own service-specific enablement that auto-creates resource discoveries across org accounts.

Additionally, **the IPAM had to be destroyed and recreated** after steps 2-4 were in place. An IPAM created before org integration is enabled retains its original (single-account) monitoring scope even after org integration is later enabled. Re-creating the IPAM after all org integration is in place lets it pick up the auto-discovery of member accounts.

The full sequence of fix PRs: #32 (Terraform delegated admin) → #33 (CLI service access + design gap in ADR-004) → manual destroy+recreate of IPAM → manual `enable-ipam-organization-admin-account` → the staging-account VPC allocation succeeded.

### Prevention

For any future IPAM in a delegated admin pattern, the order of operations matters:

1. Enable RAM sharing with org
2. Enable IPAM Organizations service access (`enable-aws-service-access`)
3. Delegate IPAM admin to the IPAM-hosting account
4. Enable IPAM-specific org admin (`enable-ipam-organization-admin-account`)
5. **Only then** create the IPAM itself

Creating the IPAM before steps 1-4 produces an IPAM whose monitoring scope is stuck at single-account. Destroy and recreate is the only fix — there is no API to retroactively update an IPAM's monitoring scope.

Runbook troubleshooting and ADR-004 Consequences both document this.

### Lessons

- **AWS cross-account features often have multiple independent prerequisites.** RAM enablement, generic org delegation, and IPAM-specific enablement all looked redundant on paper. They are not.
- **"The pool is visible" ≠ "the pool is usable."** Describe APIs and mutation APIs can disagree on cross-account state. Always test end-to-end, not just describe.
- **Some AWS services have a service-specific enablement API distinct from the generic `aws organizations` delegation.** IPAM, GuardDuty, Security Hub, Config all have this pattern. Each variant needs its own enablement call.
- **IPAM monitoring scope is sticky at creation time.** Not documented prominently, but consequential: enabling org integration later does not retroactively update IPAMs created earlier.
- **The design-at-ADR-time model was incomplete.** The original mental model ("RAM share + OrgID condition is how cross-account works") did not cover IPAM, because IPAM monitoring is a service-level concept, not a resource-policy concept. ADR-004 updated with a 'Design gap' note acknowledging this.

---

## Incident 8 — SSO account assignment already existed outside Terraform state

**Date**: 2026-04-14 (Phase 3c, PR #39 baseline apply)
**Severity**: S3 (first post-merge baseline apply failed; recovery required before downstream layers could apply)
**Duration**: ~10 min from baseline failure to green rerun

### Symptom

Immediately after merging PR #39, the `terraform-apply-baseline.yml` workflow ran and failed on the `management/bootstrap` job:

```
Error: creating SSO Account Assignment for USER
(f384f8b2-c051-7074-9b66-b7f5d029ba8a): already exists
```

The failing resource was the newly added `aws_ssoadmin_account_assignment.bin_staging_platform_admin`, which PR #39 introduced in `management/bootstrap/sso-assignments.tf` to ensure the `AWSReservedSSO_PlatformAdmin_*` role existed in the staging account before a downstream layer's access-entries lookup ran.

Other baseline layers (`shared/bootstrap`, `shared/ipam`, `staging/bootstrap`, `management/scps`) succeeded as no-ops. Only the newly added SSO resource failed.

### Root cause

The operator had already assigned the `PlatformAdmin` permission set to user `bin` in the staging account during Phase 0 SSO setup — via the Identity Center Console, not via Terraform. That assignment has existed since Phase 0 but was never captured in Terraform state because no Terraform code referenced it.

The AI's project memory read from the start of Phase 3c claimed:

> Permission set: `PlatformAdmin`... Assigned to: user `bin` → account `aegis-management` (`186052668286`)

which was accurate at the time of writing but became stale when additional Console-side assignments were made. The memory was never updated.

When PR #39 added the `aws_ssoadmin_account_assignment` resource to Terraform expecting to create a new assignment, AWS rejected the `CreateAccountAssignment` API call with a `ConflictException` because the assignment already existed — exactly the surface we now wanted Terraform to manage, but the `create` action is not idempotent over an existing out-of-band assignment.

### Detection

Immediate: the baseline workflow run (ID `24380624416`) reported `failure` on `Apply management/bootstrap` under a minute after merge. The error text pointed directly at "already exists" which is the unambiguous signature of untracked pre-existing state, not a permissions or config problem.

The principal ID in the error (`f384f8b2-c051-7074-9b66-b7f5d029ba8a`) matched the Identity Store user ID for user `bin`, confirming the target of the conflict.

### Resolution

One-time `terraform import` to bring the existing assignment into Terraform state, from the operator's laptop using `aegis-management-admin` SSO session:

```bash
export AWS_PROFILE=aegis-management-admin
aws sso login --sso-session aegis

cd terraform/environments/management/bootstrap
terraform init
terraform import aws_ssoadmin_account_assignment.bin_staging_platform_admin \
  "f384f8b2-c051-7074-9b66-b7f5d029ba8a,USER,251774439261,AWS_ACCOUNT,arn:aws:sso:::permissionSet/ssoins-6987a8402843ec85/ps-57f7e67ee5853241,arn:aws:sso:::instance/ssoins-6987a8402843ec85"

terraform plan   # "No changes."
```

State file updated on S3 (state lives in `aegis-shared`, CMK-encrypted). Baseline workflow re-triggered via `gh run rerun 24380624416 --failed` — now a no-op for the imported resource, green.

The import ID format for `aws_ssoadmin_account_assignment` is `PRINCIPAL_ID,PRINCIPAL_TYPE,TARGET_ID,TARGET_TYPE,PERMISSION_SET_ARN,INSTANCE_ARN` — documented in the AWS provider docs but easy to mis-type (every field is a comma-separated positional argument with no field names).

### Prevention

**When Terraform-izing AWS resources that may have been created by hand earlier, check for existing state before adding the `create` resource block.** The quickest per-service checks:

| Service | Pre-flight check |
|---------|------------------|
| SSO assignments | `aws sso-admin list-account-assignments --instance-arn <arn> --account-id <target> --permission-set-arn <arn>` |
| IAM roles | `aws iam get-role --role-name <name>` |
| KMS keys (by alias) | `aws kms describe-key --key-id alias/<name>` |
| S3 buckets | `aws s3api head-bucket --bucket <name>` |
| OIDC providers | `aws iam list-open-id-connect-providers` |

If any of these returns a hit, the Terraform code needs to be introduced as either (a) a data source, or (b) a resource block with immediate `terraform import` in the same landing PR.

**Memory claims about AWS state are not authoritative over AWS itself.** The AI's memory captured the SSO assignment state as it existed at Phase 0, but the operator made additional Console assignments during Phase 1-2 without updating the memory. Trust CloudTrail and live AWS API calls over cached summaries.

The `sso-assignments.tf` file in this repo now documents this class of hazard inline: future additions to that file must be paired with a "does this assignment already exist?" check before committing.

### Lessons

- **"Already exists" is the signature of a Console-first-then-IaC-later lifecycle.** Any project that did manual Console work before introducing Terraform will hit this class of error at least once. The recovery path (`terraform import` with the correct ID format) is the same across services; the ID format is the hard part.
- **`aws_ssoadmin_account_assignment.create` is not idempotent over pre-existing state**, unlike e.g. `aws_iam_role_policy_attachment` which idempotently re-applies. Check each resource type's create behavior before relying on "apply, it'll sort itself out."
- **Identity Center assignment IDs have six comma-separated fields in a fixed order.** The format is not intuitive and is undocumented in the error message when import fails. Keep a reference copy somewhere accessible (this incident's Resolution section now serves that purpose).
- **A pre-flight assertion in one layer that another layer applied correctly pays off.** Had the baseline failure left `management/bootstrap` state broken in a different way (e.g., the assignment not created but no AWS-side resource to import), the next consumer of the `AWSReservedSSO_PlatformAdmin_*` role would have failed loudly with a message pointing back at the SSO assignment.

---

## Incident 9 — Dependabot PR plans silently fail because secrets live in a separate namespace

**Date**: 2026-04-15 (post-Phase-3c, routine Dependabot sweep)
**Severity**: S4 (CI-only; no AWS impact, no cost exposure)
**Duration**: ~30 min (first failing PR seen → fix verified green)

### Symptom

All 11 open Dependabot PRs (3 recent GitHub Actions version bumps + AWS provider v5→v6 across the Terraservice layers + 2 checkout/credentials bumps) fail the required `Terraform Plan` status check. Every matrix leg (`management/bootstrap`, `management/scps`, `shared/bootstrap`, `shared/ipam`, `staging/bootstrap`) reports the same result.

PR comments posted by the workflow show:

```
### ❌ Terraform Plan: `shared/ipam`
**Result:** Plan failed

<details><summary>Plan Output</summary>
```
```
</details>
```

The plan output fenced block is empty. No visible error. `gh run view --log-failed` returns only the trailing `Fail if plan errored` step (`exit 1`) with no Terraform error text — because `continue-on-error: true` on the plan step means it is not considered the "failing" step.

Meanwhile, the identical workflow run on branches opened by the repo owner (non-Dependabot) passes all checks.

### Root cause

GitHub Dependabot-created PRs execute in a separate security context from PRs opened by human contributors. For `pull_request` events on Dependabot branches, the `secrets.*` context resolves against a **distinct secret store** ("Dependabot secrets", visible under Settings → Secrets and variables → **Dependabot** tab) rather than the "Actions secrets" store. This is GitHub's defense against Dependabot PRs exfiltrating Actions secrets during dependency updates.

Our workflow materializes the landing-zone config file like this (`.github/workflows/terraform-plan.yml:40-45`):

```yaml
- name: Write config
  run: |
    mkdir -p config
    cat <<'EOFCONFIG' > config/landing-zone.yaml
    ${{ secrets.LANDING_ZONE_CONFIG }}
    EOFCONFIG
```

For Dependabot runs, `secrets.LANDING_ZONE_CONFIG` expands to an empty string because the Dependabot secret store has never been populated. The heredoc still executes, writing an empty file. `terraform init` succeeds because `backend.tf` contains only static strings (bucket name is not a secret per CLAUDE.md's security model). Then `terraform plan` evaluates `config.tf`:

```hcl
locals {
  config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))
}
```

`yamldecode("")` fails with `on line 1, column 1: missing start of document.` Terraform writes this to stderr and exits 1. `continue-on-error: true` prevents the step from being marked failed; `steps.plan.outputs.stdout` captures stdout only (empty) and the PR comment interpolates that empty string between code fences — producing the "Plan failed / empty output" symptom the developer saw.

### Detection

Four-step bisection that the investigator (future me) should recognize:

1. **`gh run list` shows matrix-wide failure, not a single leg** → suggests something environmental, not code-specific.
2. **`gh run view --log-failed` returns no useful error** → the error is not in a step with `if: failure()` semantics; need the raw log.
3. **`gh run view --job <id> --log` with manual grep for `error` / `terraform`** surfaces the actual `yamldecode` message. The trick: `--log-failed` only prints steps whose conclusion is `failed`, but `continue-on-error: true` rewrites the conclusion to `success`. The real error is in a step `--log-failed` never prints.
4. **Contrast check**: `Terraform Init` succeeded in the same run → backend config loaded fine → the config that failed must be something read at plan-time (i.e., `file()` / `yamldecode()`), not init-time. That narrows the failure to the config-file materialization step.

The bisection, once understood, is generalizable: **"init green + plan red" almost always points at a `file()` or `templatefile()` reading something the runner can't see.**

### Resolution

**Immediate unblock** — populate the Dependabot secret store with the same value as the Actions store:

```bash
gh secret set LANDING_ZONE_CONFIG \
  --app dependabot \
  -R BinHsu/aegis-aws-landing-zone \
  < config/landing-zone.yaml

# Verify the Dependabot namespace now has the secret:
gh secret list --app dependabot -R BinHsu/aegis-aws-landing-zone
# Expect: LANDING_ZONE_CONFIG  <timestamp>
```

Then trigger reruns on the failing PRs:

```bash
gh run rerun <run_id> --failed -R BinHsu/aegis-aws-landing-zone
```

Result on verification rerun (PR #18 `codeql-action v3→v4`): 6/6 matrix legs green within 35 seconds.

### Prevention

**Codified in `scripts/configure-github.sh`.** The fork-setup script now sets `LANDING_ZONE_CONFIG` in BOTH namespaces in a single invocation, with an explicit pointer to this incident in the comment block so future forkers who skip the script and try to configure secrets manually via the UI will find this note when the error surfaces:

```bash
# Actions namespace — used by workflows triggered by human PRs and workflow_dispatch
gh secret set LANDING_ZONE_CONFIG < "${CONFIG_FILE}"

# Dependabot namespace — used by workflows triggered by Dependabot PRs
# (separate store by design; see docs/incidents.md §9)
gh secret set LANDING_ZONE_CONFIG --app dependabot < "${CONFIG_FILE}"
```

**Not changed in the workflow.** The `continue-on-error: true` on the plan step combined with a `Comment Plan on PR` step that renders `steps.plan.outputs.stdout` is the documented GitHub Actions pattern for posting plan output as a PR comment regardless of success/failure. Removing `continue-on-error` would mean the `Comment Plan on PR` step is skipped on failure, losing the PR feedback loop on legitimate plan errors (resource conflicts, provider errors, IAM denials). A better long-term improvement is to capture stderr into an output and interpolate BOTH stdout and stderr into the PR comment — tracked as a follow-up, not gated on this incident because the root cause was the secret, not the logging.

**Portfolio-level hardening** (done in the same session, same PR family): enable GitHub-native security controls that protect the "zero static credentials by design" stance — Secret Scanning alerts, Secret Scanning push protection, Dependabot vulnerability alerts. All free on public repos, all high-signal for a landing-zone reference implementation.

### Lessons

- **Dependabot secrets are a separate namespace from Actions secrets, and the error never says so.** Any public repo that uses Dependabot AND has a workflow that reads `secrets.*` must populate both stores. GitHub's UI has separate tabs for them (Settings → Secrets → Actions / Dependabot / Codespaces / Environments), but the `${{ secrets.X }}` syntax is identical for all four — and when Dependabot's store is empty, the expression silently resolves to empty string rather than failing loudly. The failure surfaces only in the downstream tool (Terraform, in our case) that tries to use the empty value, far from the root cause.

- **`continue-on-error: true` will hide stderr when the downstream step only renders stdout.** This is fine when errors are rare and the PR comment is just one of several surfaces (status checks, annotations, logs). It becomes opaque when the annotation is also generic (`exit 1`) and the log is buried behind `--log-failed` (which filters by step conclusion, not by content). The fix is not to remove `continue-on-error` — the comment pattern is worth keeping — but to know the bisection path: `gh run view --job <id> --log | grep -iE 'error|failed'` bypasses the filter.

- **`terraform init` succeeding is not proof that the workspace is ready to plan.** Init reads `backend.tf` (static HCL) and provider requirements (lockfile + `.terraform.lock.hcl`). It does NOT evaluate `locals`, `data`, `resource`, or any expression that calls `file()`, `templatefile()`, or `yamldecode()`. A CI config-materialization bug (missing secret, wrong path, Windows line endings in a heredoc) produces "init green + plan red" and mimics a Terraform bug. When that pattern appears, check config files on the runner before debugging the Terraform.

- **Signed-off behavior of the platform boundary matters more than any one code line.** The repo's security model already documented "account IDs and bucket names are not secrets; access keys are" (CLAUDE.md). That line is what made `backend.tf` static and portable — and it is also what let init still pass even when the user-facing config was empty. The same principle needs a matching line for GitHub's secret-store partitioning: **"Actions and Dependabot secret stores are separate by design; fork setup must populate both, or Dependabot PRs will fail in ways that look like Terraform bugs."** Added to the fork-setup script as an executable form of that rule.

---

## Incident 10 — Terraform plan stampede fails on S3 native state lock under Dependabot bulk rebase

**Date**: 2026-04-15 (same session as Incident 9; discovered while verifying the Incident 9 fix)
**Severity**: S4 (CI-only; self-inflicted via operator-issued parallel rebases)
**Duration**: ~5 min detect (after second matrix-wide failure in the same session)

### Symptom

Ten open Dependabot PRs were each given `@dependabot rebase` via `gh pr comment`, issued by a single `for` loop with 2 s between each comment. Dependabot processed them as a batch over ~1 min. Each rebase pushed a new commit → each PR's `Terraform Plan` workflow fired almost simultaneously. Nine of the ten runs failed within seconds with:

```
Error: Error acquiring the state lock
Error message: operation error S3: PutObject, https response error,
Terraform acquires a state lock to protect the state from being written
```

The one that succeeded (`checkout-6`) happened to be the first to acquire the S3 lock for each of its matrix legs; the other nine got their `PutObject` rejected because the lock object already existed and retried until default timeout (zero) elapsed immediately.

### Root cause

Two compounding factors, each benign in isolation:

1. **S3 native state locking is strictly serial per state file.** The Terraform `s3` backend with `use_lockfile = true` (the mode this project adopted instead of DynamoDB, per ADR-003) creates a sibling object `<state-key>.tflock` and enforces exclusive hold via conditional `PutObject`. This is correct and cheap — but it is single-holder, no queue. Concurrent planners either acquire immediately or retry locally under `-lock-timeout`. Default `-lock-timeout=0` means "fail instantly if lock is held."

2. **`terraform plan` acquires the same state lock as `terraform apply`.** Even though plan is logically read-only, the s3 backend still writes a lockfile during plan (to preserve snapshot consistency for potential apply). Multiple concurrent plans against the same state file therefore serialize in the same queue as applies would.

Under a Dependabot bulk rebase, ten PRs × six matrix legs = sixty plan invocations targeting six state files (one per Terraservice layer). Each state file gets ten racers with `-lock-timeout=0`. Exactly one wins per leg per moment; the other nine fail and the workflow reports "Plan failed" with the stdout of Terraform's lock error.

The operator-side amplifier was issuing all ten rebase comments in a tight loop rather than letting them drift naturally. Dependabot does not rate-limit its rebase response; it processes comments at its normal cadence (single-digit seconds).

### Detection

The failure class was recognizable immediately because this was the **second** matrix-wide failure of the session with **different error text**:

1. First wave (Incident 9): `yamldecode: missing start of document` — six legs × multiple PRs.
2. After fixing the Dependabot secret and verifying `codeql-action` went 6/6 green, I bulk-reran the other nine with `gh run rerun --failed`. Same matrix-wide failure pattern, but error text changed to `Error acquiring the state lock`. Different symptom, different root cause. Same shape (all-legs failure across all PRs) because both causes are environmental, not code-specific.

General rule for bisection: **matrix-wide failure across unrelated PRs is always environmental.** The question is only which part of the environment — secrets, state, permissions, quota, external dependency. When one of those is ruled out, work down the list.

### Resolution

**Preventive fix to the plan workflow.** Adding `-lock-timeout=10m` to the plan command (`.github/workflows/terraform-plan.yml`) lets each planner wait up to 10 min for the lock instead of failing instantly. Under Dependabot stampede, the ten runs serialize: each plan takes ~30 s, so the last one in the queue waits ~5 min — well inside the timeout. In the no-contention case (normal human PR), the flag is a no-op.

```diff
-        run: terraform plan -no-color -input=false -detailed-exitcode
+        run: terraform plan -no-color -input=false -detailed-exitcode -lock-timeout=10m
```

Not applied to the apply workflow in this incident's fix, because:

- Apply is always gated behind explicit `workflow_dispatch` + GitHub Environment approval. There is no scenario where ten applies race for the same state file.
- A stuck state lock on apply is a real operational signal the operator should see quickly (someone killed a previous run, `force-unlock` may be needed). Masking that with a generous timeout would hurt, not help.

If a future session shows apply-side contention, the flag can be added there too — tracked as "apply lock-timeout" follow-up, but not done now (YAGNI).

**Operational correction**: the nine failed PRs can be re-driven either by another `@dependabot rebase` (now safe — lock-timeout makes the stampede self-serializing) or by waiting for Dependabot's next poll which rebases onto the lock-timeout-fixed main.

### Prevention

- **Workflow-level**: `-lock-timeout=10m` on plan, as above. Eliminates this class of failure for any future concurrent-PR scenario (Dependabot, multiple humans reviewing different PRs, CI rerun loops).
- **Operator-level**: when bulk-operating on Dependabot PRs (or any action that triggers many workflows at once), space the triggers OR rely on downstream serialization. Posting ten `@dependabot rebase` comments with a `sleep 2` in a loop is **not** spacing — GitHub and Dependabot will happily process them faster than the Terraform back-end can serialize plans. If you find yourself writing a `for` loop that triggers workflows, prefer `until`-loop polling that waits for the previous run to finish before starting the next.
- **No new `configure-*.sh` change.** The script sets secrets, not timeouts. Timeouts are CI config, correctly located in the workflow.

### Lessons

- **`use_lockfile = true` (S3 native locking) is strictly first-come-first-served with no queue.** The choice to drop DynamoDB (ADR-003) is correct for this project — DynamoDB's lease-based locking had the same "no queue, fails fast" semantics anyway — but it means explicit `-lock-timeout` on every Terraform CLI invocation in CI is the *only* defense against concurrent-plan failure. It is not optional for a repo that uses matrix plans AND expects multiple PRs open simultaneously.

- **"Plan is read-only" is a mental model trap.** Plan writes a state lockfile. Plan writes a plan file if `-out` is used. Plan may refresh remote state and rewrite it (until `-refresh=false`). Anything about plan that assumes "no side effects" is wrong at the infrastructure boundary, even if the Terraform resources themselves are untouched. The practical consequence: any CI orchestration that assumes "plans are fine to run in parallel" needs lock-timeout, not just "I thought plan was read-only."

- **Two incidents in one session with identical symptoms but different root causes is a pattern, not a coincidence.** Both Incident 9 and 10 presented as "matrix-wide Plan failure across all six Terraservice layers and all Dependabot PRs." Different errors, same shape. When the second wave appeared, the shape of the failure ruled out code-level bugs (different provider versions, different GitHub Action bumps) and pointed at environment. That shape-based filter is worth remembering as a first-cut triage tool — *if every leg fails the same way across unrelated PRs, look outside the code.*

- **Operator batching + bot batching = quadratic pressure on shared-state systems.** I issued ten rebase comments with a 2-second gap. Dependabot consumed them in parallel. Ten PRs × six matrix legs = sixty plan invocations against six state files, arriving within ~10 seconds. This is not a theoretical edge case — it is what happens every time a batch of Dependabot PRs gets rebased simultaneously after a main-branch update. `-lock-timeout` is the generic answer. The more specific answer is: **don't batch-trigger bot workflows from the command line.** Either `@dependabot rebase` one-by-one as each preceding PR lands, or let Dependabot's own cadence handle it.

---

## Incident 11 — `MalformedPolicyDocument`: `account-alias/*` is not a valid IAM resource path (2026-05-04)

**Date**: 2026-05-04 (ADR-014 IAM scope-down rollout, PR #172 ship)
**Severity**: S3 (CI/apply failure, recovered with single hotfix PR; no AWS resources damaged)
**Duration**: ~30 min from first apply-baseline failure to PR #175 merged + apply re-run green

### Symptom

Three of four post-merge `terraform-apply-baseline.yml` runs after the original four-PR ADR-014 rollout (#171/#172/#173/#174 merged within 45 seconds of each other) failed with:

```
Error: putting IAM Role (gh-tf-apply-baseline) Policy (apply-baseline-scoped):
operation error IAM: PutRolePolicy, https response error StatusCode: 400,
MalformedPolicyDocument: IAM resource path must either be "*", root, or start
with user/, federated-user/, role/, group/, instance-profile/, mfa/,
server-certificate/, policy/, sms-mfa/, saml-provider/, oidc-provider/,
report/, access-report/.
```

The error fired three times (mgmt/bootstrap, shared/bootstrap, staging/bootstrap apply jobs across multiple workflow runs) — once for each account where `gh-tf-apply-baseline` was being created.

### Root cause

PR #172's `gh-tf-apply-baseline` policy (and PR #173's apply-role policy, but that failed earlier on lock contention before reaching this error) had this resource list inside the `IamScoped` Sid:

```hcl
Resource = [
  "arn:aws:iam::${local.account_id}:role/aegis-*",
  "arn:aws:iam::${local.account_id}:role/github-actions-*",
  "arn:aws:iam::${local.account_id}:role/gh-tf-*",
  "arn:aws:iam::${local.account_id}:policy/aegis-*",
  "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com",
  "arn:aws:iam::${local.account_id}:account-alias/*",   # <-- THIS LINE
]
```

`account-alias` is **not** in AWS IAM's allowed resource-path list. The IAM authorizer accepts only the segments enumerated in the error message — `user/`, `federated-user/`, `role/`, `group/`, `instance-profile/`, `mfa/`, `server-certificate/`, `policy/`, `sms-mfa/`, `saml-provider/`, `oidc-provider/`, `report/`, `access-report/`. Account-alias operations (`iam:CreateAccountAlias` / `DeleteAccountAlias` / `ListAccountAliases`) are account-level — AWS only accepts `Resource: "*"` for these.

The bug was authored by a subagent generating the `gh-tf-apply-baseline` .tf during the ADR-014 implementation. Static analysis (terraform validate, Checkov, Terraform's own JSON schema check) all passed: the JSON is syntactically valid; AWS rejects only at the actual `PutRolePolicy` API call. Plan-time was happy; apply-time was not.

### Detection

Standard apply-baseline workflow run logs. The error is unusually descriptive for AWS IAM (it enumerates all valid path segments verbatim), so categorization was instant. Distinguishing the real bug from the concurrent `Error acquiring the state lock` failures (caused by all four apply-baseline runs racing each other on shared layers) required reading job-level conclusions per-workflow-run rather than just the top-level conclusion.

### Resolution

PR #175 ([commit 27eb246](https://github.com/BinHsu/aegis-aws-landing-zone/pull/175)):

1. Removed `"arn:aws:iam::${local.account_id}:account-alias/*"` from the `IamScoped` Sid's `Resource` list in all three baseline-role files (`management/`, `shared/`, `staging/`).
2. Added a new `AccountAliasManagement` Sid:
   ```hcl
   {
     Sid    = "AccountAliasManagement"
     Effect = "Allow"
     Action = [
       "iam:CreateAccountAlias",
       "iam:DeleteAccountAlias",
       "iam:ListAccountAliases",
     ]
     Resource = "*"
   }
   ```
3. Added a comment in each file explaining why the split exists, so future readers (forkers / next operator) don't re-introduce the same bug.

After PR #175 merged, the next `terraform-apply-baseline.yml` run (sha=27eb246) succeeded across all 8 baseline layers.

### Prevention

- **Memory entry**: `feedback_iam_resource_path_account_alias.md` documents the full list of valid IAM resource-path segments and tags account-alias / password-policy / account-summary as common landmines requiring a separate Sid with `Resource: "*"`.
- **Subagent prompts** for IAM policy drafting going forward should explicitly call out: "do not put `account-alias/`, `password-policy/`, `account-summary/`, or any non-listed segment in IAM resource ARNs — those actions are account-level and need their own `Resource: \"*\"` Sid."
- Local `terraform validate` does NOT catch this; only AWS `PutRolePolicy` does. Hotfix-after-the-fact is the realistic flow until AWS adds plan-time policy validation (unlikely; the API contract is the contract).

### Lessons

- **Static analysis is not enough for IAM policies**. Terraform validate, Checkov, JSON schema validation all passed for the buggy policy. AWS's PolicyValidation only fires at the actual API call. The implication: **CI pre-flight cannot catch this class of bug**; only post-merge apply does. Budget for one hotfix-PR cycle after every new IAM policy ships, and make the apply log readable enough that the bug categorizes in <2 minutes.

- **The split-Sid pattern is the correct shape for mixed-resource-level / account-level policies**. AWS IAM's resource-path rules are per-action: some actions support resource-level ARNs, some are account-level only. When the policy mixes both, splitting into two Sids — one with explicit ARN list, one with `Resource: "*"` and a narrow action list — keeps the discipline tight without tripping AWS validation. This pattern is reusable for any future policy that touches account-alias / password-policy / account-summary / etc.

- **Three concurrent apply-baseline runs (from the four-PR-merge race) made the failure noisy**: `state lock` errors from the layer-locking competition obscured the real `MalformedPolicyDocument` errors until job-level conclusions were inspected. Lesson: when triaging multi-workflow-run failures, ALWAYS read jobs not just top-line. The concurrent merges were themselves a poor pattern — see Incident 12's note on serial vs parallel rollout.

---

## Incident 12 — Scoped-role policy bug gauntlet, chicken-and-egg break-glass, and drift-correction overwrite (2026-05-04)

**Date**: 2026-05-04 (ADR-014 four-role cutover, PR #177 → PR #180)
**Severity**: S2 (cascading PR CI failures + multiple break-glass operations + apply-baseline self-lock; ~3 hours from first failure to stable state)
**Duration**: ~3 hours (06:08 first PR #177 plan failure → 09:00ish stable post-fourth-break-glass + manual workflow_dispatch)

### Symptom

PR #177 (the workflow cutover that points `terraform-plan.yml` at the new `gh-tf-plan` role) opened with all the matrix Plan jobs running against the scoped role for the first time. Several of the matrix Plan jobs failed:

- `Plan management/bootstrap` — `sso:ListInstances` AccessDenied (data source `aws_ssoadmin_instances`)
- `Plan shared/ipam` — `ec2:GetIpamPoolCidrs` UnauthorizedOperation
- additional layers — `kms:Decrypt` AccessDenied (cross-service condition mismatch on SSM SecureString reads)

Each fix exposed the next bug. Three rounds of break-glass `aws iam put-role-policy` were needed before the Plan jobs went green. Then after PR #180 merged (the .tf-side alignment commit), `terraform-apply-baseline.yml` for sha=bf3debe failed on `Apply management/bootstrap` — same `sso:ListInstances` error, even though the role had been break-glass-fixed earlier.

### Root cause

Four distinct policy-design bugs in the new `gh-tf-plan` role policy (and the same bugs replicated in `gh-tf-apply-baseline` mgmt-account variant):

1. **`sso-admin:` IAM prefix bug** — the policy used `sso-admin:Describe* / List* / Get*` as actions. AWS IAM's authorizer recognizes `sso:` prefix for IAM Identity Center actions. The CLI verb (`aws sso-admin <command>`) and the IAM service prefix differ; AWS docs sometimes label the section `sso-admin` for display while the IAM authorization key is `sso:`.

2. **Missing `ec2:Get*`** — IPAM CIDR reads (`GetIpamPoolCidrs`, `GetIpamPoolAllocations`) use `Get*` verbs. The policy only had `ec2:Describe*` + `ec2:DescribeIpam*`; refresh on shared/ipam failed.

3. **KMS `ViaService` too narrow** — single condition `kms:ViaService = s3.${region}.amazonaws.com` covered cross-account state-bucket reads but blocked SSM SecureString reads (which need `kms:ViaService = ssm.${region}.amazonaws.com` to decrypt the `/aegis/staging/*` parameter values during refresh of layers that read SSM PS).

4. **Missing `identitystore:Get*`** — the `data "aws_identitystore_user"` lookup in `management/bootstrap/sso-assignments.tf` calls `identitystore:GetUserId`. Policy had `Describe*` + `List*` but not `Get*`.

These four bugs were latent in the .tf code from the original PR #171 / PR #172 / PR #173 ship. They didn't surface during pre-cutover CI because the legacy `github-actions-terraform` Admin role (`*:*` permissions) bypassed all IAM authorization. Once PR #177 swapped `terraform-plan.yml` to use `gh-tf-plan` (scoped, read-only), all four bugs surfaced over three sequential CI re-runs.

The chicken-and-egg: to update a role's policy in AWS via `terraform-apply-baseline.yml`, the workflow needs the role-policy update to take effect during apply. But for `gh-tf-apply-baseline` (mgmt account), its own policy had the same `sso-admin:` bug — refresh on `data "aws_ssoadmin_instances"` failed, terraform aborted, the fix never landed via the normal path. Direct API calls (`aws iam put-role-policy`) were blocked by the `deny-iam-privilege-escalation` SCP from PR #174 / ADR-015 — the operator's `AWSReservedSSO_PlatformAdmin_*` SSO role is intentionally NOT in the SCP allow-list (the SCP's threat model: "even SSO Admin shouldn't be able to do IAM privilege escalation directly").

The drift-correction overwrite: after the third round of `gh-tf-plan` break-glass (round 3 added `identitystore:Get*` for mgmt) succeeded and PR #177 merged, PR #177's merge-induced `terraform-apply-baseline.yml` run (sha=1a51536) ran terraform apply. The `apply-baseline` path filter matched the plan-role .tf paths. At sha=1a51536, the .tf code for the plan-role had the fixes (PR #177's last commits) but the .tf code for `gh-tf-apply-baseline` (mgmt) still had `sso-admin:*` (PR #180 hadn't been opened yet). Terraform refresh saw `sso:*` in AWS (the round-2 break-glass version), compared to .tf which said `sso-admin:*`, computed a drift, and applied the .tf — overwriting the break-glass fix back to the buggy version. The next apply-baseline run (sha=bf3debe, PR #180 merge) then failed because AWS state had been silently reverted.

### Detection

Each of the four bugs was detected by reading the failed CI run's job log via `gh run view --log-failed`. The `AccessDeniedException` / `UnauthorizedOperation` error messages are precise enough that the missing IAM action prefix is unambiguous from the error string. The drift-correction overwrite was harder to diagnose — the failure log read identical to the original bug, and only inspecting the apply-baseline workflow run history (specifically the `gh run list --workflow terraform-apply-baseline.yml`) revealed an additional run (sha=1a51536, PR #177 merge) had executed between the break-glass and the failing PR #180 apply. The plan output `~ "sso-admin:*" -> "***"` (with `***` being GitHub Actions' content-redaction of `sso:*`) confirmed that the apply at sha=1a51536 had reverted the policy.

### Resolution

A four-round break-glass procedure across two days, with five distinct steps:

**Round 1** (~06:25 UTC): Lifted `Bash(aws iam put-*:*)` from `.claude/settings.local.json` permissions deny list. Wrote `/tmp/plan-role-policy.json` with the first three bug fixes (sso prefix, ec2:Get* added, KMS ViaService expanded to s3+ssm). Ran `aws iam put-role-policy` against `gh-tf-plan` in mgmt. Shared and staging put failed with SCP `deny-iam-privilege-escalation` denial because PlatformAdmin SSO is not in the SCP allow-list.

**Round 1.5** (~06:30 UTC): Detached SCP `p-0jgmxs51` from org root (`r-fk0d`) via `aws organizations detach-policy` from the management account (mgmt is exempt from member SCPs). Slept 30 seconds for SCP propagation. Ran `aws iam put-role-policy` for `gh-tf-plan` in shared and staging. Re-attached SCP to root.

**Round 2** (~07:00 UTC): Wrote `/tmp/baseline-mgmt-policy.json` with sso prefix fix. Ran `aws iam put-role-policy` against `gh-tf-apply-baseline` in mgmt. Restored deny.

**Round 3** (~07:09 UTC): PR #177 CI re-run revealed the fourth bug (`identitystore:Get*` missing). Lifted deny again, edited `/tmp/plan-role-policy.json` to add the missing action, re-ran `put-role-policy` against mgmt's `gh-tf-plan` only. Restored deny.

**Round 4** (~07:35 UTC): After PR #180 apply failed due to drift-correction overwrite, lifted deny once more. Re-ran `put-role-policy` for mgmt baseline-role. Restored deny. Then `gh workflow run terraform-apply-baseline.yml --ref main` to manually trigger apply — this time the .tf at sha=bf3debe matched the now-correct AWS state (both sso:*), so apply was a no-op for the role policy and the data-source refresh passed.

Total break-glass operations: 5 `put-role-policy` calls + 1 SCP detach/attach round + 4 deny-list lift/restore cycles + 1 manual `gh workflow run`.

### Prevention

- **Memory entry**: `feedback_iam_resource_path_account_alias.md` (extended from Incident 11) covers the IAM action prefix gotcha — `aws sso-admin <cmd>` CLI verb vs `sso:` IAM prefix. Same memory will be extended again with the `identitystore:Get*` and `ec2:Get*` patterns next session.
- **Memory entry** (new, captured next session): "Break-glass IAM patches must be paired with the same fix in .tf code, OR the next `terraform apply` that touches the layer will revert it via drift correction." This is the load-bearing lesson; without it, the round-4 drift-overwrite dance recurs.
- **Build `aegis-emergency-*` role family** to provide a non-detach-SCP recovery path. ADR-015 OQ-1 reserved the namespace but didn't materialize the role. After this incident, OQ-1 graduates from aspirational to actionable — next session should ship `aegis-emergency-bin-recovery` with a trust policy that admits the operator's SSO PlatformAdmin and a permission policy with the `iam:*`-on-prefix-scope needed for break-glass. The SCP `deny-iam-privilege-escalation` already allows `aegis-emergency-*` via its bypass list; the role just needs to exist.
- **Avoid concurrent merges of multiple PRs that touch the same Terraservice layer.** Four merges in 45 seconds (PR #171/#172/#173/#174 at 05:14:51-05:15:34) caused state-lock contention across all baseline layers, which masked the real `MalformedPolicyDocument` failure (Incident 11) until job-level inspection. Sequential merges (one merge → wait for apply-baseline to complete → next merge) are the disciplined default. Branch-protection's `Require branches to be up to date` was set to `false` on the ruleset, which permitted the racy concurrency; tightening that single setting would have forced serial merges naturally.
- **Cutover PRs (the ones that swap `role-to-assume:` from Admin to scoped role) should expect a 1-3-round CI debug cycle.** Latent IAM action coverage gaps that were masked by the Admin role surface only after the cutover. Plan budget accordingly. The ADR-014 rollout's PR-2/PR-4/PR-6/PR-7 split into separate cutover PRs (per role family) is the right shape — each cutover surfaces its own bug surface.
- **Read the apply-baseline workflow's `paths:` filter when reasoning about whether a merge will trigger a re-apply**. PR #176 (docs only), PR #178 / PR #179 (workflow YAML only) did NOT trigger apply-baseline. PR #177 (.tf changes inside `terraform/environments/.../bootstrap/**`) DID. The path filter is non-obvious and the chicken-and-egg cascade depended on knowing exactly when each merge triggered an apply.

### Lessons

- **AWS CLI verb namespace ≠ IAM action prefix.** The mismatch between `aws sso-admin list-instances` and `sso:ListInstances` is invisible at static analysis time — `terraform validate` accepts the JSON, Checkov accepts the JSON, AWS accepts the policy at `PutRolePolicy` time, only fails at policy *evaluation* time when the role tries to call the action and authorization searches for the prefix. AWS docs occasionally use both `sso` and `sso-admin` in different contexts, deepening the confusion. **Rule of thumb**: when authoring a policy that gates a CLI verb, look up the action in the AWS Service Authorization Reference, not in the CLI command help. The prefix listed there is the IAM-recognized one.

- **Drift correction is a feature that bites operators who break-glass.** Terraform's "the .tf is the source of truth" is correct in steady state. During an incident where AWS state has been hand-fixed but .tf has the bug, the next apply will revert. **Mitigation**: any break-glass hand-fix must be paired with a `.tf` PR that lands the same fix in code, in the same merge window. If the break-glass runs at 07:00 and the `.tf` PR can't merge until 09:00, an apply triggered by an unrelated PR at 08:00 that touches the same layer will silently revert. The discipline: **break-glass and code-fix are inseparable. Author both, ship the code-fix in the same hour, ideally in the same commit-set as a draft PR before the break-glass runs.**

- **The `deny-iam-privilege-escalation` SCP is working as designed when it locks out the operator.** This was the first time the SCP fired against a real privilege-escalation attempt (the operator using PlatformAdmin SSO to call `iam:PutRolePolicy` on member accounts). The fact that it locked the operator out is the security guarantee; the discomfort of the recovery path (detach SCP from root → fix → re-attach) is the expected cost. Designing a smoother recovery path (the `aegis-emergency-*` role) is a follow-up, not a redesign — the SCP's deny-by-default is correct.

- **Operator authority over the org root is the real break-glass key.** SCPs do not apply to the management account, so `aws organizations detach-policy` from mgmt admin is always available. This is AWS's own escape hatch design — the management account is the "ultimate admin" and cannot be bricked by its own SCPs. Knowing that this escape hatch exists, and being willing to use it under audit (CloudTrail logs the detach + re-attach + intermediate API calls in clear), is the difference between "SCP is a soft suggestion" and "SCP is a real lock". This incident validated both directions.

- **Subagent-authored IAM policies need empirical testing under load.** The four bugs in `gh-tf-plan` were all introduced by subagents during PR #171's policy authoring (or its `aegis-baseline`-equivalent in PR #172). Each subagent produced JSON that passed local validation, then AWS rejected at the actual call site. The full surface of "what action prefix does this CLI verb actually evaluate against" is not in any subagent's training data with reliable accuracy. **Mitigation**: subagent IAM policy work should ALWAYS be paired with a manual review pass against the AWS Service Authorization Reference, OR a smoke test (apply to a throwaway role + try to invoke the action + observe the result) BEFORE shipping the .tf. This adds 10-15 minutes per policy; saves the 2-3 hour debug cycle this incident produced.

- **Ruleset `Require branches to be up to date` should be `true`**. The original ruleset was set with `strict_required_status_checks_policy: false` because of an oversight during the same morning's Rulesets migration. With `false`, four PRs were merged within 45 seconds without any rebase requirement, producing state-lock contention. With `true`, GitHub would have refused to merge a PR whose base was behind main — forcing a rebase per merge — which would have serialized the four merges naturally. The setting was corrected to `true` later in the same session via PR #180. Future rulesets should include this from the start.

---

## Incident 13 — IAM eventual-consistency race during apply that adds permissions + new resources together (2026-05-04)

**Symptom**: PR #186 (Tier 3 detective controls) merged. The triggered `Terraform Apply (Baseline)` workflow failed on `Apply management/bootstrap` with two errors back-to-back: `AccessDeniedException` on `SNS:CreateTopic` for `aegis-security-alerts` and `AccessDeniedException` on `events:TagResource` for `aegis-detective-failed-oidc-assumption`. Other 7/8 baseline jobs were green.

**Root cause**: AWS IAM eventual consistency on policy updates. The same `terraform apply` ran two operations in close sequence: (a) `aws_iam_role_policy.gh_tf_apply_baseline` modification adding the new `EventsForDetectiveRule` (`events:*` scoped to `rule/aegis-detective-*`) and `SnsForDetectiveTopic` (`sns:*` scoped to `aegis-security-alerts*`) Sids, completing at `09:54:17.24Z`; then (b) `aws_sns_topic.security_alerts` creation, attempted at approximately `09:54:17.7Z`. The active assumed-role session's permission cache had not yet propagated the new Sids when the SNS API was called — sub-second window, but real. Once the policy propagated (low tens of seconds), the new resources became creatable.

**Detection**: GitHub Actions email notification on workflow failure. Main thread `gh run view --log` confirmed the AccessDeniedException pattern. The error message `"User: arn:aws:sts::186052668286:assumed-role/gh-tf-apply-baseline/GitHubActions is not authorized to perform: SNS:CreateTopic ... because no identity-based policy allows the SNS:CreateTopic action"` is the AWS-standard signature for "policy says no" — but in this case the policy DID say yes; the session cache hadn't received the update yet.

**Resolution**: `gh run rerun --failed` re-triggered just `Apply management/bootstrap`. By retry time, the policy had fully propagated. Apply succeeded in one shot, creating SNS topic + EventBridge rule + target + topic policy.

**Prevention**: PR #187 added a `time_sleep.wait_for_apply_baseline_policy_propagation` resource in `terraform/environments/management/bootstrap/detective-controls.tf`:

```hcl
resource "time_sleep" "wait_for_apply_baseline_policy_propagation" {
  depends_on      = [aws_iam_role_policy.gh_tf_apply_baseline]
  create_duration = "30s"
}
```

The new SNS topic and EventBridge rule then `depends_on = [time_sleep.wait_for_apply_baseline_policy_propagation]`. `triggers` is intentionally omitted — the sleep fires on first create only; once the resource exists in state, subsequent applies pass through in zero time. No latency tax on routine apply. The pattern works for any future apply that adds permissions and creates the resources permitted by them in the same plan.

**Lessons**:

- **Same-apply policy-update + resource-create has a built-in IAM race**. Terraform's resource graph orders the policy update before the resource create only if there's an explicit dependency. Without `depends_on`, the AWS provider may pipeline both concurrently. Even with `depends_on`, AWS IAM's eventual consistency means the assumed-role session cache may evaluate the pre-update policy for tens of seconds AFTER `aws_iam_role_policy` returns success.

- **`gh run rerun --failed` is the one-line recovery** for this race. The race is bounded in time (seconds, not minutes), so a single retry virtually always succeeds. No partial state to clean up — the failed CreateTopic / PutRule did not commit anything.

- **`time_sleep` without `triggers` is the cleanest cold-apply guard**. With `triggers = {policy_id = aws_iam_role_policy.X.id}`, the sleep would re-fire every time the policy changes. Without `triggers`, it fires once on first create — which is exactly the race window. Forker cold-apply benefits the most: their first apply does not need the manual rerun step PR #186's merge needed.

- **30s buffer is empirically sufficient for an account this size**. Larger orgs with more attached policies may need longer; the value should be tuned per account if cold-apply still races at 30s. The pattern is the same; only the duration changes.

---

## Incident 14 — Concurrent baseline-apply runs race the S3 state lock

**Date**: 2026-05-18 (Dependabot PRs #197–#205 merged in a burst)
**Severity**: S4
**Duration**: ~30 min detect + recover

### Symptom

After nine Dependabot PRs were merged in a roughly 30-second burst, `terraform-apply-baseline.yml` reported most of its layer jobs failed. The baseline layers (`management/bootstrap`, `management/scps`, `shared/bootstrap`, `shared/ipam`, `staging/bootstrap`) failed with `Error acquiring the state lock` / `api error PreconditionFailed`.

### Root cause

**No concurrency guard on `terraform-apply-baseline.yml`.** Each merge to `main` triggers a baseline-apply run. Nine merges in ~30 seconds spawned overlapping runs that contended for the same S3 state-lock objects. The loser of each race failed with `PreconditionFailed` on the lock `PutObject` — failing at lock *acquisition*, before any plan or apply, so each such failure was a clean no-op that changed nothing.

### Detection

`gh run list --workflow="Terraform Apply (Baseline)"` showed a wall of `completed/failure`. `gh run view --log-failed` confirmed every failure was a lock-acquisition `PreconditionFailed`, not a plan or apply error.

### Resolution

Re-ran the latest baseline-apply run once, with no other baseline-apply runs active:

```bash
gh run rerun <run-id>
```

With no contention every baseline layer acquired its lock and applied cleanly. No `terraform force-unlock` was needed: the contention failures never held a lock to leave stale.

### Prevention

- Add a `concurrency:` group to `terraform-apply-baseline.yml` (`group: baseline-apply`, `cancel-in-progress: false`) so baseline applies serialize instead of racing. Until that lands, do not merge multiple baseline-touching PRs in a burst — pace them.

### Lessons

- "All plan CI green" does not imply "apply will succeed." Plan jobs run isolated; apply jobs contend for shared state. A repo with apply-on-merge automation needs a CI concurrency guard or paced merges — the absence of both is a latent defect that only surfaces under a merge burst.
- When a batch operation yields a wall of failures, classify each before reacting. Here every failure was a transient lock race, cleared by one serial re-run — but confirming that (rather than assuming it) is what made a single `gh run rerun` the right fix instead of a force-unlock scramble.

---

## Adding a new incident

Append new sections at the bottom, before this footer, using the format below. The next incident to be recorded is Incident 15.

```markdown
## Incident NN — <short descriptive title>

**Date**: YYYY-MM-DD (<phase and related PR>)
**Severity**: S1 / S2 / S3 / S4
**Duration**: <approximate detect+recover time>

### Symptom
<what the operator saw>

### Root cause
<what actually went wrong, one level deeper than the symptom>

### Detection
<how you knew>

### Resolution
<exact commands / steps — copy-paste-able>

### Prevention
<what to do so this doesn't happen again>

### Lessons
<what transfers to unrelated future work>
```

One incident = one section. Do not edit existing entries except to fix factual errors. If an earlier incident's prevention advice is later invalidated by a new incident, write the new incident rather than revising the old one — the historical record matters.
