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
**Severity**: S3 (staging/network apply blocked on cross-account state read)
**Duration**: ~20 min to understand and design the fix

### Symptom

`staging/network` used `data "terraform_remote_state" "shared_ipam"` to read IPAM pool IDs. Plan failed:

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

The CMK was introduced in PR #25 (staging VPC + NAT, kept in Draft to avoid NAT cost). The CMK code lived only on the PR #25 branch, not on main. However, the CMK itself *had been applied locally* to AWS (to unblock testing of staging/network).

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

**Date**: 2026-04-13 (Phase 3b, PR #25 merge)
**Severity**: S3 (staging/network apply blocked after NAT cost had started)
**Duration**: ~10 min detect + fix

### Symptom

After PR #25 merged and the apply workflow ran, `staging/network` failed at VPC creation:

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

### Resolution

Added `aws_organizations_delegated_administrator` in `management/bootstrap/organization-features.tf`:

```hcl
resource "aws_organizations_delegated_administrator" "ipam" {
  account_id        = local.config.accounts.shared.id
  service_principal = "ipam.amazonaws.com"
}
```

Applied from management account. IPAM immediately recognized all org accounts as monitored. `staging/network` apply then succeeded on retry.

### Prevention

When setting up IPAM in a non-management account, the delegation is mandatory, not optional. Document both prerequisites up front:

1. `aws_ram_sharing_with_organization` — for pools to be RAM-shareable
2. `aws_organizations_delegated_administrator` for `ipam.amazonaws.com` — for IPAM to monitor org accounts

Both go in `management/bootstrap`. Both must apply before any cross-account IPAM consumption.

Runbook troubleshooting now documents this.

### Lessons

- AWS cross-account features often have multiple independent prerequisites. RAM enablement and IPAM delegation looked redundant on the surface; they are not.
- "The pool is visible" ≠ "the pool is usable." Describe APIs and mutation APIs can disagree on cross-account state.
- When a multi-account AWS service has both a "trusted service access" setting and a "delegated admin" setting, both likely need attention. Enabling one without the other is a common gap.

---

## Adding a new incident

Append new sections at the bottom, before this footer, using the format:

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
