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

**Date**: 2026-04-13 (Phase 3b, PR #25 through PR #33)
**Severity**: S3 (staging/network apply blocked; fix required three separate PRs and a destroy-recreate of IPAM)
**Duration**: ~90 min total across multiple failed apply cycles

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

### Resolution (three layers, in order)

This incident was not a single fix — the problem had three independent causes, each surfaced only after the previous one was resolved. The final working setup requires all four of the following:

1. **RAM sharing with org enabled** (already in place from earlier work) — `aws_ram_sharing_with_organization.main` in `management/bootstrap`. Lets pools be RAM-shareable.
2. **Organizations trusted service access for IPAM** — `aws organizations enable-aws-service-access --service-principal ipam.amazonaws.com`. One-time CLI, idempotent. The AWS Terraform provider does not expose this as a standalone resource; managing it via `aws_organizations_organization` would conflict with Control Tower's ownership.
3. **Delegated administrator for IPAM** — `aws_organizations_delegated_administrator` resource for `ipam.amazonaws.com` pointing at shared. Requires step 2 as prerequisite, otherwise fails with `ConstraintViolationException: You must enable service access before you delegate an administrator`.
4. **IPAM org admin enablement (IPAM-specific API)** — `aws ec2 enable-ipam-organization-admin-account --delegated-admin-account-id <shared>`. This is a DIFFERENT API from step 3. Generic org delegation does not automatically enable IPAM's org integration — IPAM has its own service-specific enablement that auto-creates resource discoveries across org accounts.

Additionally, **the IPAM had to be destroyed and recreated** after steps 2-4 were in place. An IPAM created before org integration is enabled retains its original (single-account) monitoring scope even after org integration is later enabled. Re-creating the IPAM after all org integration is in place lets it pick up the auto-discovery of member accounts.

The full sequence of fix PRs: #32 (Terraform delegated admin) → #33 (CLI service access + design gap in ADR-004) → manual destroy+recreate of IPAM → manual `enable-ipam-organization-admin-account` → staging/network apply succeeded.

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

## Incident 8 — OIDC trust policy missing `environment:` subject claim for workflow_dispatch

**Date**: 2026-04-13 (Phase 3b, PR #35 workflow split)
**Severity**: S4 (operator inconvenience; teardown path blocked until fix)
**Duration**: ~5 min

### Symptom

After splitting `terraform-apply.yml` into baseline/workload/teardown workflows (PR #35), the first manual trigger of `terraform-teardown-workload.yml` immediately failed at the OIDC auth step:

```
Error: Could not assume role with OIDC:
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

Baseline apply (on push to main) still worked. Plan (on PR) still worked. Only workload-dispatch failed.

### Root cause

GitHub Actions produces different `sub` (subject) claims in the OIDC token depending on the trigger and whether the job uses a GitHub Environment:

| Trigger | `sub` value |
|---------|-------------|
| push to main | `repo:<org>/<repo>:ref:refs/heads/main` |
| pull_request | `repo:<org>/<repo>:pull_request` |
| workflow_dispatch + `environment: X` | `repo:<org>/<repo>:environment:X` |

The original OIDC role trust policy (written in Phase 2) only allowed the first two. The newly introduced workload workflows use GitHub Environments (`workload-apply` and `workload-teardown`) for approval gates, which produced a third subject pattern the role refused to trust.

### Detection

AWS STS returned `NotAuthorized` on `AssumeRoleWithWebIdentity`. The error message was generic, but the pattern (baseline works, workload doesn't) localized the problem quickly to the role trust policy plus the new environment-scoped workflows.

### Resolution

Added two new subject patterns to the staging OIDC role's trust policy:

```hcl
github_oidc_subjects = [
  "repo:${org}/${repo}:ref:refs/heads/main",
  "repo:${org}/${repo}:pull_request",
  "repo:${org}/${repo}:environment:workload-apply",      # new
  "repo:${org}/${repo}:environment:workload-teardown",   # new
]
```

Baseline apply auto-updated the trust policy on merge to main. The teardown workflow was re-triggered.

**Secondary gotcha — IAM propagation lag.** The first re-trigger of the teardown workflow (~2 minutes after the baseline apply reported success) still failed with the same `NotAuthorized` error. `aws iam get-role` confirmed the trust policy was in fact updated. A second re-trigger ~1-2 minutes later succeeded. IAM changes are usually fast but not instant — a ~4 minute propagation window between "apply reports success" and "OIDC `AssumeRoleWithWebIdentity` sees the new trust policy" is real. Not documented in AWS SLAs but observed in practice. If you see `NotAuthorized` after a fresh trust-policy apply, wait a few minutes and retry before debugging further.

### Prevention

When adding a GitHub Actions workflow that uses a new `environment:` value, update the corresponding role's OIDC trust policy in the same PR. Inline comment in `staging/bootstrap/oidc-github.tf` now explains which subject pattern each trigger produces so future environments are added consistently.

Generalized rule for this repo: **any change to the workflow surface area that introduces a new OIDC subject claim must include the matching role trust-policy update**. This should ideally be codified as a pre-merge check but is documented-and-trusted for now.

### Lessons

- OIDC `sub` claims carry more context than operators often realize. `environment:` is only one example — `job_workflow_ref`, `ref_type`, `actor` all affect the claim and can all be used in trust policies for tighter scoping.
- Different GitHub Actions triggers produce materially different tokens. A trust policy tested against one trigger type is not guaranteed to work for another.
- Fast-moving debug path: check CloudTrail for the STS AssumeRoleWithWebIdentity failure, read the full `token` claim set the request presented, compare with the trust policy's allowed subjects.

---

## Incident 9 — SSO account assignment already existed outside Terraform state

**Date**: 2026-04-14 (Phase 3c, PR #39 baseline apply)
**Severity**: S3 (first post-merge baseline apply failed; staging/platform apply blocked until state recovered)
**Duration**: ~10 min from baseline failure to green rerun

### Symptom

Immediately after merging PR #39 (staging EKS platform layer), the `terraform-apply-baseline.yml` workflow ran and failed on the `management/bootstrap` job:

```
Error: creating SSO Account Assignment for USER
(f384f8b2-c051-7074-9b66-b7f5d029ba8a): already exists
```

The failing resource was the newly added `aws_ssoadmin_account_assignment.bin_staging_platform_admin`, which PR #39 introduced in `management/bootstrap/sso-assignments.tf` to ensure the `AWSReservedSSO_PlatformAdmin_*` role existed in the staging account before `staging/platform`'s access-entries lookup ran.

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
- **The check block pattern in `staging/platform/access-entries.tf` did its job.** Had the baseline failure left `management/bootstrap` state broken in a different way (e.g., the assignment not created but no AWS-side resource to import), the subsequent `staging/platform` apply would have failed loudly at the `AWSReservedSSO_PlatformAdmin_*` role lookup with a message pointing back at the SSO assignment. Pre-flight assertion in one layer that another layer applied correctly pays off.

---

## Incident 10 — `kubernetes_manifest` plan-time schema fetch breaks cold bootstrap

**Date**: 2026-04-14 (Phase 3c, first cold apply of staging/platform; PR #43 → fix in PR #44)
**Severity**: S3 (blocked first cluster apply; no AWS resources created)
**Duration**: ~5 min to diagnose + patch

### Symptom

The first `terraform-apply-workload.yml` run with the `staging/platform` layer enabled failed at PLAN phase, before creating any cluster resources:

```
Error: Failed to construct REST client
  cannot create REST client: no client config
  with kubernetes_manifest.karpenter_default_ec2nodeclass
  with kubernetes_manifest.karpenter_default_nodepool
  with kubernetes_manifest.argocd_root_app
```

Network layer applied fine. Platform layer's EKS cluster resource would have been created successfully if plan had reached apply — but plan itself errored on three `kubernetes_manifest` resources.

### Root cause

`hashicorp/kubernetes`'s `kubernetes_manifest` resource fetches the target CRD's OpenAPI schema from the Kubernetes API server **at plan time** to validate the manifest shape. This is correct for day-2 operations (catches manifest typos without attempting to apply). It is fatal for day-0 bootstrap: on the first cold apply, the cluster does not exist yet, so there is no Kubernetes API server to query, so no schema, so no plan.

The three `kubernetes_manifest` resources in question were the Karpenter `NodePool`, the Karpenter `EC2NodeClass`, and the ArgoCD root `Application` — all CRD instances whose CRDs are installed by upstream Helm charts elsewhere in the same Terraform configuration. Terraform's dependency graph correctly ordered `helm_release.karpenter` → `kubernetes_manifest.karpenter_default_nodepool`, but the provider's plan-time behavior ignored the graph — it tried to reach the cluster unconditionally.

### Detection

The error message was direct and pointed at the exact resources. Diagnosis was 30 seconds of reading. The broader pattern ("how do I bootstrap an EKS cluster + CRD instances in one Terraform apply?") is a well-known issue in the Terraform + Kubernetes community; searching for the error string leads immediately to the usual solutions.

### Resolution

Swap the three `kubernetes_manifest` resources for `kubectl_manifest` from the `gavinbunney/kubectl` provider. That resource applies raw YAML via `kubectl apply -f -` at apply time and does not do plan-time schema validation. Plan succeeds without a live cluster; apply waits for the cluster + CRD install + runs the manifest apply.

Changes in PR #44:

- `versions.tf`: add `gavinbunney/kubectl ~> 1.19`
- `providers.tf`: configure `kubectl` provider with the same `aws eks get-token` exec-plugin auth as the `kubernetes` and `helm` providers
- `karpenter-nodepool.tf`, `argocd.tf`: replace three `kubernetes_manifest` resources with `kubectl_manifest` using `yaml_body = yamlencode({...})`

### Prevention

**Use `kubectl_manifest` (gavinbunney) for CRD instances that are bootstrapped in the same Terraform apply that installs the CRDs.** Reserve `kubernetes_manifest` (hashicorp) for manifests targeting CRDs that are guaranteed to exist before plan — typically day-2 configuration changes to a steady-state cluster.

The two providers are otherwise functionally similar; the plan-time behavior is the only meaningful difference. The choice is not about quality; it is about *when the cluster exists relative to when plan runs*.

### Lessons

- **"Apply-time validation" vs "plan-time validation" is a real axis for Kubernetes-touching Terraform resources.** Every provider in this space has a stance on it. `helm_release` validates at apply; `kubernetes_manifest` at plan; `kubectl_manifest` at apply. Pick per the lifecycle stage the resource is bootstrapping.
- **Dependency graphs describe apply-time ordering, not plan-time ordering.** A `depends_on` that says "apply this after the Helm release" does not tell the resource to postpone its plan-time schema fetch. This is a subtlety worth noting because it's counter-intuitive.
- **Search the error string before inventing a workaround.** "Failed to construct REST client: no client config" is a well-indexed community failure mode. The solution pattern (kubectl_manifest) is not novel.

---

## Incident 11 — EKS Access Policy ARN namespace is not IAM

**Date**: 2026-04-14 (Phase 3c, first cold apply of staging/platform, same run as Incident 12)
**Severity**: S3 (blocked Access Entry creation; cluster came up but no principals were mapped to cluster-admin)
**Duration**: ~2 min to diagnose

### Symptom

Platform layer apply partially succeeded — EKS cluster + Fargate profiles + OIDC provider + Access Entries all created. Then two `aws_eks_access_policy_association` resources errored:

```
Error: creating EKS Access Policy Association
  (aegis-staging#<principal>#arn:aws:iam::aws:policy/AmazonEKSClusterAdminPolicy):
  InvalidParameterException: The policyArn parameter format is not valid
```

### Root cause

EKS Access Policies live in their **own ARN namespace**, distinct from IAM Managed Policies. The correct format is:

```
arn:aws:eks::aws:cluster-access-policy/<PolicyName>
```

The Terraform code used the IAM form, `arn:aws:iam::aws:policy/<PolicyName>`. The names look parallel (`AmazonEKSClusterAdminPolicy` exists in both namespaces as conceptually the same cluster-admin role), but the ARN prefix is different and the `aws_eks_access_policy_association` API strictly validates the namespace.

This is the kind of mistake that happens precisely because the two namespaces look similar — `AmazonEKSClusterAdminPolicy` feels like an IAM managed policy name, so it gets the IAM ARN prefix by reflex.

### Detection

The error message was unambiguous (`policyArn parameter format is not valid`), and the offending ARN was right in the error text. AWS documentation for [EKS Access Policies](https://docs.aws.amazon.com/eks/latest/userguide/access-policies.html) confirms the `arn:aws:eks::aws:cluster-access-policy/...` format.

### Resolution

Single-character namespace fix in `access-entries.tf`:

```diff
- policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterAdminPolicy"
+ policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
```

Applied in both the CI-role and operator-SSO-role associations. Inline comment added above the resources explaining the namespace distinction so the next reader (or AI agent) doesn't re-make the mistake.

### Prevention

**When a new AWS service introduces its own ARN namespace for policies, read the ARN format from that service's docs, not by pattern-matching on IAM.** Services that have their own policy namespaces (non-exhaustive, as of 2026): EKS (`arn:aws:eks::aws:cluster-access-policy/...`), SES (`arn:aws:ses:<region>:<account>:email-identity-policy/...`), Organizations SCPs (`arn:aws:organizations::<account>:policy/o-.../service_control_policy/...`). Always reach for the service's own docs first.

The inline comment in `access-entries.tf` points at this incident for future reference.

### Lessons

- **AWS resource naming looks parallel, but the ARN prefix is canonical.** A policy name alone does not tell you which service namespace it belongs to. Always carry the full ARN.
- **"Looks like it should work" is not a validity check for AWS ARNs.** There is no way to test-before-apply other than reading the docs or trying the API. The AWS Terraform provider could offer nicer error messages for this case (flag when the wrong namespace is used for a resource type) but does not.
- **The AI agent making this mistake is a symptom of training-data pattern-matching.** IAM policy ARNs are much more common in public code than EKS Access Policy ARNs. The safest habit when wiring a new AWS service in Terraform is to read the resource documentation and copy-paste the ARN example, not to compose the ARN from memory.

---

## Incident 12 — Public `public_access_cidrs` lockdown incompatible with CI-managed Helm

**Date**: 2026-04-14 (Phase 3c, first cold apply of staging/platform, same run as Incident 11)
**Severity**: S2 (full platform bootstrap blocked; cluster existed but could not be configured)
**Duration**: ~10 min to diagnose; ~30 min to fix-and-document (this incident + ADR-013 design iteration + runbook 002 rewrite)

### Symptom

After the cluster created successfully, the Helm release for Karpenter failed:

```
Error: Kubernetes cluster unreachable:
  Get "https://E2BD20D584DF52A0937C50D9FB60108D.gr7.eu-central-1.eks.amazonaws.com/version":
  dial tcp 63.182.209.11:443: i/o timeout

  with helm_release.karpenter
```

The error's `63.182.209.11` was the GitHub Actions runner's egress IP. The EKS endpoint is at `...eks.amazonaws.com`. The runner could not complete a TCP connection to that endpoint.

### Root cause

The cluster was provisioned with `public_access_cidrs = ["5.28.82.226/32"]` — the operator's home IP. GitHub-hosted Actions runners egress from AWS-wide IP ranges that rotate per job; there is no way to pre-whitelist a specific runner IP, and the published ranges (`https://api.github.com/meta` → `.actions`) are roughly 50 CIDRs that change periodically.

The `/32` lockdown was chosen originally (ADR-013 "Control plane endpoint") as defense-in-depth on top of IAM auth. That intent was correct for operator-driven `kubectl`, but **incompatible with CI-managed Helm/kubectl**. The CI runner's AWS SDK calls (to STS, EKS, IAM) continued to work because those hit public AWS API endpoints that are not CIDR-gated; the **Kubernetes API** (a different endpoint class, gated by `public_access_cidrs`) rejected the runner's connection.

The design blind spot was conflating "who can reach Kubernetes" with "who is the operator." In a single-operator lab with fully manual `kubectl`, `/32` lockdown works. In a lab where Terraform itself is the primary client of the Kubernetes API (via `helm_release` and `kubectl_manifest`), the client is the CI runner and its IP surface is wide and ephemeral.

### Detection

The error message was direct and pointed at the runner's public IP vs the cluster's DNS. A `whois 63.182.209.11` or a quick search confirmed the IP belongs to GitHub Actions' egress ranges. The conflict with the configured `public_access_cidrs` was immediate.

### Resolution

Relax `public_access_cidrs` to `["0.0.0.0/0"]` for the lab. The four auth layers (TLS, AWS IAM SigV4, EKS Access Entries, Kubernetes RBAC) remain the real gate; the CIDR lockdown was defense-in-depth above them, and the lab accepts losing that particular layer in exchange for CI-managed platform-as-code.

Documented fully in:

- `docs/decisions/013-eks-architecture.md` → new "Design iteration — public_access_cidrs relaxed to 0.0.0.0/0" section, which supersedes the original Decision paragraph and lays out the two corporate-fork alternatives (Option Z: GitHub Actions IP ranges; Option Y: self-hosted VPC runners).
- `docs/runbooks/002-eks-access.md` → rewritten around the four-layer auth model; the IP drift diagnostic order is downgraded to step 5 (from step 1) because the CIDR is no longer the likely failure site.
- `config/landing-zone.example.yaml` → the default value is now `0.0.0.0/0` with inline comments documenting Options Y and Z.
- `config/landing-zone.yaml` (operator's local) → `0.0.0.0/0`; GitHub secret `LANDING_ZONE_CONFIG` refreshed in the same session.

### Prevention

**Before choosing a CIDR lockdown for any public AWS endpoint, enumerate the clients that will use it, including CI/CD.** If any client's IP is not pre-knowable, either (a) open to `0.0.0.0/0` and rely on IAM, (b) whitelist the CI provider's published ranges, or (c) move that client into the network (self-hosted runners, private endpoint + VPN). There is no fourth option.

**"Defense in depth at the network layer" is an aesthetic, not a capability, when IAM already gates authentication.** This is not a universal statement — an Ingress Controller with no authentication in front of it absolutely needs a network-layer gate — but for authenticated AWS API endpoints (EKS, STS, IAM), the network gate is redundant with IAM and costs more in operational friction than it buys in reduced blast radius.

The corporate-fork options (Y, Z) in ADR-013 document the path to re-add a network gate if the deployment context requires it (e.g., SOC 2, FedRAMP, or an internal audit checklist that flags `0.0.0.0/0`).

### Lessons

- **Design decisions that work in isolation can conflict when composed.** The ADR-013 decisions "public endpoint with CIDR lockdown" and "CI applies cluster resources via Helm/kubectl" were each sound; their composition was not. A design-review check for "does this decision imply a client, and is that client's network reachable?" would have caught it at ADR time.
- **CI runner IPs are not whitelistable at lab budget.** A lab that depends on CI-managed cluster-API calls cannot also hold a narrow `public_access_cidrs`. Picking one of the two is a real architectural choice; forking a production-grade version that keeps both (via self-hosted runners) is a meaningful upgrade path.
- **The IAM / RBAC auth stack is the real primary gate for any IAM-authenticated AWS service.** Network-layer gates are optional hardening. This reframes how to evaluate security-in-depth trade-offs for any AWS API: enumerate the gates, identify the primary, and only add secondary gates when they don't break a functional requirement.

---

## Incident 13 — Helm does not auto-create target namespace; Fargate profile is not enough

**Date**: 2026-04-14 (Phase 3c, first cold apply after PR #45)
**Severity**: S3 (blocked Karpenter install; all downstream Helm releases also failed for the same root cause)
**Duration**: ~3 min to diagnose + single-line fix

### Symptom

The `staging/platform` apply cleared the cluster-endpoint update and both Access Policy Associations (Incident 11 fix confirmed working), then errored on the Karpenter Helm release:

```
Error: create: failed to create: namespaces "karpenter" not found
  with helm_release.karpenter
```

No Karpenter, no NodePool, no EC2 capacity, no place for downstream pods (LB Controller, ArgoCD) to schedule. A single root cause broke three resources.

### Root cause

Helm does not create the target namespace unless explicitly instructed via `--create-namespace` (Helm CLI) or `create_namespace = true` (Terraform `helm_release` resource). My `karpenter-helm.tf` omitted the flag.

The mental-model mistake was conflating **Fargate profile** with **namespace existence**. The Fargate profile in `fargate.tf` selects on `namespace = "karpenter"`: that is *a scheduling hint*, not *a namespace constructor*. It tells EKS "when a pod appears in this namespace, schedule it on Fargate" — but something else must first create the pod in a namespace that exists. That something is the Helm install, which itself needs the namespace to exist.

Fargate profile = AWS concern. Namespace = Kubernetes concern. They do not substitute for each other.

Why ArgoCD's `helm_release` had `create_namespace = true` while Karpenter's did not: I copy-pasted Karpenter's release from the Karpenter upstream docs (which assume the operator creates the namespace manually before running Helm) without thinking about which half of the responsibility Terraform was taking. ArgoCD's release was written later and had the benefit of the discovery. The AWS Load Balancer Controller installs in `kube-system`, a Kubernetes-built-in namespace, so the question never arose.

### Detection

Error message pointed directly at the missing namespace. Cross-referencing the three Helm releases (Karpenter / LB Controller / ArgoCD) made the inconsistency obvious within two minutes.

### Resolution

Single-line fix in PR #46:

```diff
 resource "helm_release" "karpenter" {
   name       = "karpenter"
   namespace  = "karpenter"
   repository = "oci://public.ecr.aws/karpenter"
+  create_namespace = true
```

Also added an inline comment documenting which dimensions are AWS-side vs K8s-side, and a pointer to this incident for future readers.

### Prevention

**Checklist for any `helm_release` in this repo** — before committing:

1. Is the target namespace a Kubernetes built-in (`kube-system`, `kube-public`, `default`)? If yes, `create_namespace` not needed.
2. Is the target namespace created elsewhere in this Terraform module (e.g., `kubernetes_namespace` resource)? If yes, `create_namespace` not needed but add `depends_on` to that resource.
3. Otherwise → **set `create_namespace = true`**.

Fargate profiles are NOT a substitute for (2) or (3). They are orthogonal — a scheduling hint for the namespace-once-it-exists.

### Lessons

- **Two-word mental mistake: "Fargate profile creates the namespace".** It does not. The two concepts operate in different control planes (AWS API vs Kubernetes API) and serve different purposes (scheduling vs object lifecycle). Keeping them separate in the mental model avoids this class of error.
- **Copy-paste from upstream docs carries hidden assumptions.** Karpenter's official install instructions assume an operator-creates-namespace step before the Helm install. Terraform translation needs to account for that assumption either by adding `create_namespace = true` or by creating a `kubernetes_namespace` resource explicitly.
- **Cascade failures from a single root cause are diagnostic signal, not noise.** Three `helm_release` errors in a row looked scary; all three traced to "Karpenter has no capacity to provision EC2 for me to land on" which traced to the missing namespace. Read the dependency graph before worrying about individual failures.

---

## Incident 14 — Karpenter EC2NodeClass rejects reserved tag prefixes at the admission webhook

**Date**: 2026-04-14 (Phase 3c, second cold apply after PR #46)
**Severity**: S3 (blocked NodePool registration; same cascade-to-Helm-timeouts pattern as Incident 13)
**Duration**: ~5 min to diagnose + two-line fix

### Symptom

Right after Karpenter installed cleanly (Incident 13 fix confirmed), `kubectl_manifest.karpenter_default_ec2nodeclass` failed at Karpenter's admission webhook:

```
Error: EC2NodeClass.karpenter.k8s.aws "default" is invalid: spec.***
  Invalid value: "object": tag contains a restricted tag matching
  kubernetes.io/cluster/
```

The NodePool manifest was not even attempted (depends on the EC2NodeClass). Without a NodePool, Karpenter had zero capacity to provision on, so `helm_release.aws_lb_controller` and `helm_release.argocd` both timed out waiting for pod scheduling on EC2 nodes that were never created.

### Root cause

Karpenter v1's admission webhook enforces that `EC2NodeClass.spec.tags` MUST NOT contain any of three reserved prefixes, because Karpenter uses those tags itself on the EC2 instances it launches:

- `kubernetes.io/cluster/*` — Karpenter auto-applies `=owned` for cluster-tag-based auto-discovery (ELB, security group, IAM scoping)
- `karpenter.sh/*` — Karpenter-internal bookkeeping
- `karpenter.k8s.aws/*` — Karpenter-internal bookkeeping

My `karpenter-nodepool.tf` merged three reserved-prefix tags into `spec.tags`:

```hcl
tags = merge(local.tags, {
  "karpenter.sh/discovery"                             = aws_eks_cluster.main.name
  "kubernetes.io/cluster/${aws_eks_cluster.main.name}" = "owned"
  "topology.kubernetes.io/region"                      = local.primary_region
})
```

Two compounding errors:

1. **Reserved-prefix tags on EC2NodeClass spec**. Karpenter's webhook rejects the whole object if any appear. The error message names only the first matched prefix; with that removed, the webhook would have rejected the next, and the next.

2. **Conceptual error with `karpenter.sh/discovery`**. That tag belongs on the target **subnets** and **security groups** — it is what `EC2NodeClass.spec.subnetSelectorTerms` and `securityGroupSelectorTerms` use to discover those resources. It does NOT belong on `spec.tags` (which applies to the EC2 instances Karpenter launches). These are *two different tagging surfaces* with *two different consumer rules*, and I conflated them.

### Detection

The webhook error named the exact restricted prefix. A 30-second search against Karpenter v1 docs confirmed the prefix-family restrictions. The concept error on `karpenter.sh/discovery` took longer to spot because the tag name is named the same as the concept but the surface is different; reading the CRD schema carefully was what clarified it.

### Resolution

Reduce `EC2NodeClass.spec.tags` to `local.tags` only (project-level user tags: `Project`, `Environment`, `ManagedBy`, etc.). PR #48:

```diff
-      tags = merge(local.tags, {
-        "karpenter.sh/discovery"                             = aws_eks_cluster.main.name
-        "kubernetes.io/cluster/${aws_eks_cluster.main.name}" = "owned"
-        "topology.kubernetes.io/region"                      = local.primary_region
-      })
+      # User-level tags only. Karpenter's admission webhook REJECTS reserved
+      # prefixes (kubernetes.io/cluster/*, karpenter.sh/*, karpenter.k8s.aws/*).
+      # Karpenter auto-applies `kubernetes.io/cluster/<name>=owned` to launched
+      # instances. `karpenter.sh/discovery` belongs on subnets/SGs (for
+      # subnetSelectorTerms / securityGroupSelectorTerms), not here.
+      tags = local.tags
```

Also added an inline comment pointing at this incident.

### Prevention

**Two-part check for any Karpenter CRD authoring**:

1. **EC2NodeClass.spec.tags** is for user-level tags that Karpenter copies onto launched EC2 instances. Anything in the reserved prefix families belongs to Karpenter itself and will be auto-applied — do not duplicate.
2. **Discovery tags** (`karpenter.sh/discovery`) go on the AWS resources that Karpenter discovers (subnets, security groups), not on the EC2NodeClass that references them via `*SelectorTerms`.

Generalization: **admission webhooks are a real validation surface distinct from Terraform plan and apply**. Terraform plan says "looks like a valid Kubernetes object"; Terraform apply hands it to the K8s API; the API calls the webhook which may reject it server-side. The error will surface only at apply time for any CRD with a webhook (Karpenter, cert-manager, ArgoCD, Istio, etc.). Expect this class of error when bootstrapping a new CRD.

### Lessons

- **Tagging surfaces multiply when a controller manages a resource**: the controller's IAM, the CRD spec, the EC2 instance itself, the subnet/SG used for discovery. Each has a separate tag consumer with separate rules. Conflating them is a common day-0 error.
- **Reserved prefix families exist precisely because the controller needs to write to them**. If I tried to write a tag in that prefix, I was (inadvertently) trying to overwrite the controller's own metadata. The webhook is protecting me from a race condition at the instance-create step.
- **Cascade failures from a single root cause, second example this week** (Incident 13 was the same pattern). Both times the cascade was "CRD validation fails → no downstream capacity → Helm releases time out on pod scheduling". This is now a recognizable diagnostic signature: "multiple Helm timeouts + one CRD validation error → fix the CRD first, the Helms will self-heal on retry."

---

## Incident 15 — EC2 Spot Service-Linked Role missing on a fresh AWS account

**Date**: 2026-04-14 (Phase 3c, third cold apply after PR #48)
**Severity**: S3 (blocked Karpenter EC2 provisioning; cascade-timeout on LB Controller + ArgoCD)
**Duration**: ~15 min to diagnose (initial misdirection) + 30 sec to fix

### Symptom

Karpenter installed successfully (post-Incidents 13, 14), detected pending pods, and created a NodeClaim. EC2 launch then failed:

```
launching nodeclaim, creating instance, with fleet error(s),
AuthFailure.ServiceLinkedRoleCreationNotPermitted: The provided credentials
do not have permission to create the service-linked role for EC2 Spot Instances.
```

Karpenter retried with exponential backoff for several minutes; each retry failed identically. LB Controller + ArgoCD Helm installs timed out waiting for EC2 capacity that never arrived.

### Root cause

AWS requires a service-linked role named `AWSServiceRoleForEC2Spot` in each account before any Spot EC2 instance can be launched. The role is **auto-created on the first Spot request** — but only if the requesting principal has `iam:CreateServiceLinkedRole` on `spot.amazonaws.com`. The Karpenter controller's IRSA policy (per ADR-013) deliberately does NOT include this permission, on the reasoning that:

1. SLR creation is a one-time per-account operation (the role persists forever once created)
2. Granting `iam:CreateServiceLinkedRole` on every reconcile cycle is gratuitous scope — it gives Karpenter IAM-creation capability for a task it needs exactly once
3. The right owner of the SLR is the account bootstrap layer, not a workload controller

So the SLR is a **cross-account-bootstrap prerequisite** of using Karpenter with Spot. In a fresh AWS account, it does not exist. The lab's staging account was itself never provisioned with the SLR (Phase 2 bootstrap didn't include it because Phase 2 didn't use Spot).

### Detection

The error message `AuthFailure.ServiceLinkedRoleCreationNotPermitted` was explicit. Brief time was lost checking Karpenter's IAM policy for the missing action (and correctly concluding it should NOT be there). The fix was to create the SLR out-of-band.

### Resolution

**One-time manual creation** (unblock current session):

```bash
export AWS_PROFILE=aegis-staging-admin
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
# Then force Karpenter to retry immediately:
kubectl delete nodeclaim <stuck-name>
# Karpenter creates a fresh NodeClaim which launches Spot without the backoff lag.
```

**Codified in Terraform** (so forkers never hit this):

```hcl
# terraform/environments/staging/bootstrap/spot-service-linked-role.tf
resource "aws_iam_service_linked_role" "spot" {
  aws_service_name = "spot.amazonaws.com"
  description      = "Service-linked role for EC2 Spot Instances (used by Karpenter)"
}
```

For the existing staging account (where the SLR was manually created during this incident), a one-time `terraform import` brought the resource under Terraform management:

```bash
cd terraform/environments/staging/bootstrap
terraform import aws_iam_service_linked_role.spot \
  "arn:aws:iam::251774439261:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot"
```

After import, `terraform plan` showed only a tag-alignment change (the manually-created SLR had no project tags).

### Prevention

Any workload controller that uses an AWS service requiring an SLR should assume the SLR exists rather than provision it. The SLR belongs in a bootstrap layer:

| Service | SLR name | Required before |
|---------|----------|-----------------|
| EC2 Spot | `AWSServiceRoleForEC2Spot` | Karpenter / any Spot launch |
| ELB | `AWSServiceRoleForElasticLoadBalancing` | AWS LB Controller |
| Organizations | `AWSServiceRoleForOrganizations` | Org-level resources (usually auto-created by Control Tower) |
| EKS | `AWSServiceRoleForAmazonEKS` | EKS cluster (auto-created on first cluster) |

For this project, EC2 Spot is the only one requiring explicit Terraform management; the others are either auto-created earlier in the stack or by Control Tower.

### Lessons

- **Service-linked roles are a hidden "account-level prerequisite" class of resource.** They don't appear in any Karpenter doc, ADR, or tutorial because they're usually created transparently on first use by a console click. Terraform-first workflows that never click the console therefore hit this on cold accounts.
- **"Least privilege" sometimes means REFUSING to grant a permission even when it would unblock the immediate failure.** Karpenter should not be granted `iam:CreateServiceLinkedRole`. The right thing is to move the SLR creation upstream, not to expand Karpenter's IAM.
- **Bootstrap layer composition: think in "what-must-exist-before" layers, not just "what-to-create."** The staging/bootstrap layer should enumerate all per-account prerequisites for the platform layer, not just the account alias and OIDC provider.

---

## Incident 16 — CoreDNS stuck Pending because it booted before the Fargate profile existed

**Date**: 2026-04-14 (Phase 3c, third cold apply; discovered during Karpenter crash investigation)
**Severity**: S2 (full cluster DNS down → cluster effectively unusable; cascade-crash of Karpenter and all workload installs)
**Duration**: ~20 min of misdirection before the root cause emerged

### Symptom

Karpenter controller in CrashLoopBackOff (12 restarts). Logs showed:

```
ERROR "ec2 api connectivity check failed"
  error: "WebIdentityErr: failed to retrieve credentials
    caused by: RequestError: send request failed
    caused by: Post https://sts.eu-central-1.amazonaws.com/:
      dial tcp: lookup sts.eu-central-1.amazonaws.com on 172.20.0.10:53:
      read udp 10.0.8.130:39174->172.20.0.10:53: i/o timeout"
```

`172.20.0.10` is the Kubernetes DNS service ClusterIP (CoreDNS). DNS was unreachable, which killed every AWS SDK call from every pod.

`kubectl get pods -n kube-system` confirmed CoreDNS × 2 both `Pending` for 136 minutes since cluster creation.

### Root cause

EKS-managed CoreDNS is installed as an EKS addon at cluster creation time, with the default `computeType: ec2`. The pods are born as regular Deployment pods needing EC2 capacity.

The Fargate profile for `kube-system` (with selector `k8s-app=kube-dns`) is created by Terraform *in the same apply* as the cluster, but:

- Fargate's mutating admission webhook injects the Fargate toleration and ServiceAccount annotation into pods **as they are created**. Pods created *before* a matching Fargate profile exists do NOT get retroactively mutated.
- Because EKS-managed CoreDNS pods come up during cluster creation, by the time the Fargate profile lands in the subsequent Terraform step, the CoreDNS pods already exist without the mutation.
- The Fargate node, once it exists, has a taint `eks.amazonaws.com/compute-type=fargate` that the unmutated CoreDNS pods cannot tolerate. So the pods stay Pending.
- No DNS means Karpenter (on its own Fargate pod that DID get mutated) can't resolve STS endpoints. Karpenter crashes before it can provision any EC2.
- No EC2 means no alternative landing site for the pending CoreDNS pods. Full cascade stall.

The mental-model error was assuming "Fargate profile with label selector = CoreDNS will just schedule on Fargate." Correct statement: "Fargate profile with label selector + pod created AFTER the profile exists = schedule on Fargate." Pods created before the profile are frozen.

### Detection

Three clues lined up:

1. Karpenter log → "DNS i/o timeout to 172.20.0.10"
2. `kubectl get pods -n kube-system` → CoreDNS Pending for 136 min
3. `kubectl describe pod coredns-*` → event log showed "1 node(s) had untolerated taint `eks.amazonaws.com/compute-type: fargate`"

The untolerated-taint event was the smoking gun. Once seen, the fix was obvious.

### Resolution

**Immediate unblock** (rollout the CoreDNS Deployment; new pods go through the Fargate webhook):

```bash
kubectl -n kube-system rollout restart deployment coredns
```

Within ~60 seconds, new pods were created, mutated by the Fargate webhook, scheduled on Fargate nodes, and Running.

**Codified in Terraform** (so forkers never hit this) — take ownership of the CoreDNS addon and declare `computeType: Fargate` explicitly:

```hcl
# terraform/environments/staging/platform/coredns-addon.tf
resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    computeType = "Fargate"
    resources = {
      limits   = { cpu = "0.25", memory = "512Mi" }
      requests = { cpu = "0.25", memory = "512Mi" }
    }
  })

  depends_on = [aws_eks_fargate_profile.kube_system]
}
```

`resolve_conflicts_on_create = "OVERWRITE"` tells EKS: the addon might already exist (EKS auto-installed it); take over and apply this configuration. With `computeType = Fargate`, EKS rewrites the CoreDNS Deployment's pod template to be Fargate-compatible before the race window opens.

### Prevention

**Any EKS addon that should schedule on Fargate must be declared via `aws_eks_addon` with `computeType: Fargate` in `configuration_values`.** This is documented in AWS docs as the canonical fix. Do not rely on "Fargate profile selector will just work" for auto-installed addons — auto-installed addons come up before the profile.

Addons this applies to (in this project):
- CoreDNS (always, since it's mandatory and lands on Fargate by design)
- kube-proxy — runs as DaemonSet on EC2, no Fargate interaction; default addon config is correct

If future addons (CNI, etc.) need Fargate, repeat the pattern.

### Lessons

- **Admission webhooks are not retroactive.** A mutating webhook rewrites pod specs at creation time; it does NOT re-run on existing pods when a matching webhook config appears later. This is documented in Kubernetes architecture but easy to forget.
- **EKS auto-installed addons behave differently from Terraform-installed Helm charts.** The auto-install happens at cluster-creation time, typically BEFORE Terraform's Fargate profile resource lands. Terraform's natural dependency graph doesn't capture this ordering because the auto-install isn't a Terraform resource.
- **A single cluster-wide dependency failing (DNS) cascades to everything.** This is the second cascade-failure incident from this phase (Incidents 13, 14 were the earlier two). The pattern continues to transfer: when N unrelated things break simultaneously, suspect a shared dependency. For this cluster, DNS is N=1.
- **Read `kubectl describe pod` events for the actual scheduler decision.** The event log's `untolerated taint` message was the direct clue to the fix; without it, the debug would have taken longer.

---

## Incident 17 — AWS Load Balancer Controller webhook endpoint not ready when ArgoCD installs

**Date**: 2026-04-14 (Phase 3c, fifth apply after post-CoreDNS recovery)
**Severity**: S3 (blocked ArgoCD install; LB Controller itself was fine)
**Duration**: ~5 min to diagnose + single-line Terraform dependency fix

### Symptom

After CoreDNS + Karpenter + LB Controller all installed cleanly (previous incidents fixed), ArgoCD's Helm install failed:

```
Error: 4 errors occurred:
  * Internal error occurred: failed calling webhook "mservice.elbv2.k8s.aws":
    failed to call webhook: Post "https://aws-load-balancer-webhook-service.kube-system.svc:443/
    mutate-v1-service?timeout=10s": no endpoints available for service
    "aws-load-balancer-webhook-service"
  ... (three more identical, one per ArgoCD Service resource)
```

`helm_release.argocd` in Terraform failed on `context deadline exceeded`. ArgoCD CRDs existed (created by the chart's pre-install hook) but none of the ArgoCD pods (argocd-server, repo-server, redis, etc.) came up.

### Root cause

AWS Load Balancer Controller installs a `MutatingWebhookConfiguration` named `aws-load-balancer-webhook` that intercepts the creation of **every** `Service` resource across the cluster (not just `type=LoadBalancer`). The webhook is backed by the controller's own pods via the `aws-load-balancer-webhook-service` ClusterIP Service.

The ArgoCD Helm chart creates ~6 Services (argocd-server, argocd-repo-server, argocd-redis, argocd-applicationset-controller, etc.) early in the install as part of creating the Deployment objects. Each Service creation triggers the webhook call. If the LB Controller's pods are NOT yet Ready (or their Service has no Endpoints), the webhook call fails with `no endpoints available`, and the Service creation aborts.

In this apply, `helm_release.aws_lb_controller` and `helm_release.argocd` ran in parallel (Terraform's dependency graph did not serialize them). LB Controller pods were still coming up on their freshly-provisioned EC2 node (Karpenter-launched seconds earlier) when ArgoCD started creating Services.

### Detection

The error text explicitly named the missing Service (`aws-load-balancer-webhook-service`) and the operation (`mutate-v1-service`). The cause was unambiguous: the webhook target wasn't ready at the time of admission.

### Resolution

Single-line dependency in `terraform/environments/staging/platform/argocd.tf`:

```hcl
resource "helm_release" "argocd" {
  # ...
  depends_on = [
    helm_release.karpenter,             # (existing) need EC2 capacity
    helm_release.aws_lb_controller,     # (new) wait for webhook endpoints
  ]
}
```

Serializes: Terraform waits for LB Controller's Helm release to be considered "deployed" (which, with Helm's default `wait = true`, means pods are Ready and their Service has Endpoints) before starting the ArgoCD install. Adds ~30-60s to first apply; reliability is worth the cost.

Also `helm uninstall argocd -n argocd` to clean the failed Helm release state from the cluster so Terraform's next install is fresh rather than an upgrade-from-failed.

### Prevention

**If a Helm chart installs a cluster-wide admission webhook (mutating or validating), every subsequent Helm chart that creates resources the webhook intercepts must `depends_on` the webhook's chart.** This is not Terraform's implicit dependency graph — Terraform sees two unrelated Helm releases, does not know one's pods admit-on-behalf-of the other's workload.

Admission webhooks to watch for in this project:
- AWS Load Balancer Controller → admits Service creations (cluster-wide)
- cert-manager (future Phase 5) → admits Certificate and Issuer creations
- Istio (future Phase 5+) → admits Pod + Service creations

For any new chart that creates these resource types, explicit `depends_on` the admission-owning chart.

### Lessons

- **Admission webhooks are a real serialization concern across independent Terraform resources.** Terraform's dependency graph considers resource attribute references; it does not consider "this cluster-wide webhook will intercept the other resource's Kubernetes objects." Humans must encode that dependency via `depends_on`.
- **Parallel Helm installs look faster but are often slower in failure cases.** The apparent parallelism saves 30-60s in the happy path; it costs 5-10 minutes of timeout + debug + uninstall + re-apply when a webhook race hits. Serialize with `depends_on` by default; optimize parallelism only when measured.
- **`MutatingWebhookConfiguration` affects scope broader than it looks.** `mservice.elbv2.k8s.aws` sounds like it's about ELB-related Services, but the admission rule matches `Service` resources of any type. Cluster-wide blast radius from every controller that installs a webhook. Review `kubectl get mutatingwebhookconfiguration` after any new controller install.

---

## Incident 18 — AmazonEKSClusterAdminPolicy allows CRD create but denies CRD delete

**Date**: 2026-04-14 (Phase 3c, first teardown after successful apply)
**Severity**: S3 (teardown blocked; Access Entries already destroyed by the time error surfaced, locking the operator out of cluster-admin to fix it)
**Duration**: ~15 min from failure to codified fix

### Symptom

The workload teardown workflow (`terraform-teardown-workload.yml`) failed mid-destroy:

```
Error: argocd/root failed to delete kubernetes resource:
  applications.argoproj.io "root" is forbidden:
  User "arn:aws:sts::251774439261:assumed-role/github-actions-terraform/GitHubActions"
  cannot delete resource "applications" in API group "argoproj.io" in the namespace "argocd"

Error: default failed to delete kubernetes resource:
  nodepools.karpenter.sh "default" is forbidden:
  User "..." cannot delete resource "nodepools" in API group "karpenter.sh"
  at the cluster scope
```

Fargate profiles, SQS queue policy, and some Helm releases had already been destroyed successfully in parallel before these errors surfaced. Two `kubectl_manifest` deletes failed on RBAC denial.

The cascading problem: by the time I tried to manually delete the stuck CRD instances using my PlatformAdmin SSO (which HAS genuine cluster-admin), my **Access Entry had already been destroyed** by the earlier teardown steps. I was locked out of the cluster while the cluster was still ACTIVE in AWS. `kubectl` returned `Unauthorized`.

### Root cause

**Primary: `AmazonEKSClusterAdminPolicy` does not grant symmetric create/delete on arbitrary CRDs.** The policy's name suggests "cluster-admin equivalent", and for most resource types (including the ones it was tested against at creation time), it behaves that way. But for certain CRD API groups — specifically `argoproj.io` and `karpenter.sh` in our observation — it allows CREATE but denies DELETE. This is inconsistent and asymmetric; Terraform's lifecycle model assumes symmetric permissions.

The gap is not documented prominently in AWS docs. Searching turns up a handful of GitHub issues across AWS / EKS and third-party CRDs reporting similar CREATE-worked-DELETE-denied behavior on cluster-admin Access Policies. AWS's position (per release notes for the Access Policy feature) is that `AmazonEKSClusterAdminPolicy` grants "similar permissions" to cluster-admin, not "equivalent." The "similar" qualifier is load-bearing.

**Secondary: teardown destroyed the Access Entries in parallel with the CRD resources, so the human workaround (go in via SSO, delete manually) became impossible while the cluster was still up.** The dependency graph allowed Access Entries and kubectl_manifest resources to destroy in parallel; Access Entries finished while CRDs failed. The only remaining path was Terraform state surgery.

### Detection

The RBAC denial error explicitly named the resource and API group. Direct. The second issue (Access Entry gone) was noticed when the manual `kubectl delete` attempt returned `Unauthorized` despite a valid SSO session — a `aws eks list-access-entries` showed only the Fargate pod role and EKS service role; both human+CI Access Entries were destroyed.

### Resolution

**Immediate unblock** — Terraform state surgery to remove the stuck resources, then re-dispatch teardown:

```bash
cd terraform/environments/staging/platform
export AWS_PROFILE=aegis-staging-admin
terraform init -input=false
terraform state rm \
  kubectl_manifest.argocd_root_app \
  kubectl_manifest.karpenter_default_ec2nodeclass \
  kubectl_manifest.karpenter_default_nodepool \
  helm_release.argocd \
  helm_release.aws_lb_controller \
  helm_release.karpenter

# Re-dispatch teardown; Terraform now destroys AWS resources only.
# CRD instances + Helm releases die with the cluster itself.
gh workflow run terraform-teardown-workload.yml -f env=staging
```

This works because the CRD resources and Helm releases exist only inside the cluster; when `aws_eks_cluster` is destroyed, everything inside is gone.

**Codified in Terraform** (so forkers never hit this) — add `kubernetes_groups = ["system:masters"]` to both Access Entries:

```hcl
resource "aws_eks_access_entry" "ci" {
  cluster_name      = aws_eks_cluster.main.name
  principal_arn     = local.ci_role_arn
  type              = "STANDARD"
  kubernetes_groups = ["system:masters"]  # ← was []
}

resource "aws_eks_access_entry" "operator" {
  # ... (count-guarded for conditional creation)
  kubernetes_groups = ["system:masters"]  # ← was []
}
```

`system:masters` is the built-in Kubernetes group that the default `cluster-admin` ClusterRoleBinding binds to. Assigning this group via Access Entry gives the principal genuine cluster-admin via the core Kubernetes RBAC machinery, bypassing the AWS Access Policy layer entirely. The `AmazonEKSClusterAdminPolicy` association can remain as a belt-and-suspenders, but the group mapping is the load-bearing mechanism.

### Prevention

**For any IAM principal that needs symmetric Terraform-managed lifecycle on arbitrary CRDs, use `kubernetes_groups = ["system:masters"]` via Access Entry.** Do not rely on `AmazonEKSClusterAdminPolicy` alone.

This matters because:
- Terraform's destroy semantics assume that whoever can create can delete
- CRDs proliferate in a platform (Karpenter, ArgoCD, cert-manager, Istio, Prometheus Operator, ...) and each new CRD may or may not be covered by AmazonEKSClusterAdminPolicy's opaque-to-us permission set
- The failure mode is invisible at apply time (create works), only surfaces at teardown

Recommendation: for break-glass / Terraform CI / operator-SSO Access Entries where the principal is trusted to have cluster-admin, always use `system:masters` group. For narrower principals (namespace-scoped developers, read-only viewers), use the appropriate narrower Access Policy without `system:masters`.

### Lessons

- **"Cluster-admin equivalent" from a cloud provider is not the same as `cluster-admin` from Kubernetes.** When AWS docs say "similar", read "similar" not "equivalent". The difference emerges on CRDs and admission webhooks — surfaces the provider's own policy template can't statically enumerate.
- **Destroy-order parallelism can create unrecoverable-by-operator states.** Teardown destroyed Access Entries in parallel with the resources that needed them; by the time I noticed the RBAC error, my remedy path (SSO-based manual delete) was already gone. Explicit `depends_on` in the resources that need the operator's access to exist could have kept the window open longer — but this is ultimately a design limitation of "parallel destroy of interdependent things".
- **Terraform state surgery (`terraform state rm`) is a legitimate recovery tool, not a hack.** When a resource's dependencies have already been destroyed out from under it, state removal + re-apply-without-it is the correct path. It is documented in Terraform's own recovery guides; treat it as an intentional tool.
- **The K8s `system:masters` group is the escape hatch from cloud-provider Access Policy gaps.** Future AWS EKS products and competitors will likely converge on similar gaps; `system:masters` mapped via native Kubernetes RBAC is the portable solution.

---

## Incident 19 — Karpenter destroy order leaves orphan EC2 blocking VPC teardown

**Date**: 2026-04-14 (Phase 3c, first clean teardown after successful apply)
**Severity**: S3 (teardown stuck; manual EC2 termination needed; $0.01/hr continues on orphan until noticed)
**Duration**: ~10 min from teardown failure to diagnosis + manual fix

### Symptom

Teardown workflow failed at `Destroy staging/network` with:

```
Error: deleting EC2 Subnet (subnet-0db08821a19a43869): operation error EC2:
  DeleteSubnet, https response error StatusCode: 400,
  api error DependencyViolation: The subnet 'subnet-...' has dependencies
  and cannot be deleted.
```

VPC was still `available` in AWS. `aws ec2 describe-network-interfaces` showed 3 ENIs attached to subnets in the VPC, two of them tagged `aws-K8S-i-0ec1f06025554bd8f` — Kubernetes-attached ENIs tied to an EC2 instance. `aws ec2 describe-instances` confirmed instance `i-0ec1f06025554bd8f` was still running, tagged `karpenter.sh/nodepool=default`.

The cluster itself was gone (`aws eks describe-cluster` returned `ResourceNotFoundException`). But the Karpenter-provisioned EC2 that it used to host was still alive, blocking subnet deletion.

### Root cause

Karpenter-provisioned EC2 instances are managed via Karpenter's `NodeClaim` CRD, not via AWS Auto Scaling Groups. The expected teardown order is:

1. `kubectl delete nodepool default` → Karpenter drains + deprovisions NodeClaims → EC2 instances terminate, ENIs release
2. `helm uninstall karpenter` → remove the controller (once nothing needs it)
3. `terraform destroy` → destroy AWS resources (IAM, Fargate profiles, cluster, VPC)

In this session's teardown, the ordering was broken in two ways, compounding into an orphan:

**Primary: `terraform state rm` skipped the Karpenter deprovision step.** During Incident 18 recovery, I ran `terraform state rm helm_release.karpenter kubectl_manifest.karpenter_default_nodepool ...` to unblock teardown (CI role couldn't delete CRDs due to Incident 18's policy gap). Removing these from state meant Terraform no longer even attempted the deprovision sequence; it went straight to destroying the cluster. Karpenter controller was torn down with the cluster before its NodeClaim had a chance to drain the EC2.

**Secondary: even without state-rm, Terraform's default destroy order is racy.** `kubectl_manifest.karpenter_default_nodepool` destroy submits a delete API call to the Kubernetes API (asynchronous). Terraform does NOT wait for Karpenter to actually finish deprovisioning the EC2; it just waits for the Kubernetes API to accept the delete. By the time `helm_release.karpenter` destroys (seconds later), the controller is gone and any in-flight EC2 termination is abandoned.

This is a known class of issue with controllers that manage external resources — the CRD represents *intent*, not the *actual resource*. Terraform managing the CRD sees the intent gone; it does not see the external resource linger.

### Detection

AWS error `DependencyViolation` on subnet delete was the signal. `aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID"` showed the stuck ENIs. `aws ec2 describe-instances` (with the ENI's attached instance ID) showed the orphan.

### Resolution

**Immediate unblock** — manually terminate the EC2 instance:

```bash
export AWS_PROFILE=aegis-staging-admin
aws ec2 terminate-instances --region eu-central-1 --instance-ids i-0ec1f06025554bd8f
# Wait ~60s for termination + ENI release
aws ec2 describe-network-interfaces --region eu-central-1 \
  --filters "Name=vpc-id,Values=$VPC_ID"
# Expected: empty. Re-dispatch the teardown workflow.
```

Teardown then completed normally.

**Codified in Terraform + workflow** (so forkers never hit this):

Two mechanisms together:

**A. `kubectl_manifest.karpenter_default_nodepool` waits for EC2 termination on destroy.**
Use `provisioner "local-exec" when = "destroy"` to invoke `kubectl wait --for=delete nodeclaim --all --timeout=10m` AFTER the NodePool delete is submitted. Terraform won't proceed to destroying helm_release.karpenter until Karpenter has finished draining its NodeClaims (and thus the EC2s).

```hcl
# terraform/environments/staging/platform/karpenter-nodepool.tf
resource "kubectl_manifest" "karpenter_default_nodepool" {
  yaml_body = yamlencode({ ... })

  depends_on = [kubectl_manifest.karpenter_default_ec2nodeclass]

  # On destroy, wait for Karpenter to actually deprovision EC2 before
  # letting downstream resources (helm_release.karpenter) destroy.
  # Without this, the NodePool delete submits asynchronously and the
  # controller is gone before EC2 termination finishes — the EC2s
  # become orphans blocking subnet destroy. See Incident 19.
  provisioner "local-exec" {
    when    = destroy
    command = "kubectl wait --for=delete nodeclaim --all --timeout=10m || true"
  }
}
```

Notes on this approach:
- `|| true` — if the wait times out or kubectl itself errors (cluster already gone), we continue rather than wedge the destroy
- The `kubectl` binary must be available on the runner/operator machine (GitHub Actions runners have it; local operator has it per runbook 002/003)
- Auth comes from the same exec-plugin chain as the kubectl / helm providers

**B. Teardown workflow sweeps orphan EC2 before Terraform destroy.**
Add a pre-step to `terraform-teardown-workload.yml` that brute-force terminates any EC2 tagged by Karpenter before Terraform runs. This is the safety net for cases where state has drifted (like this session's `terraform state rm` recovery).

```yaml
# .github/workflows/terraform-teardown-workload.yml
jobs:
  destroy-platform:
    steps:
      - name: Sweep orphan Karpenter-provisioned EC2 instances
        if: inputs.env == 'staging' || inputs.env == 'prod'
        run: |
          IDS=$(aws ec2 describe-instances \
            --filters "Name=tag-key,Values=karpenter.sh/nodepool" \
                      "Name=instance-state-name,Values=running,pending,stopping,stopped" \
            --query 'Reservations[].Instances[].InstanceId' \
            --output text)
          if [ -n "$IDS" ]; then
            echo "Terminating orphan Karpenter instances: $IDS"
            aws ec2 terminate-instances --instance-ids $IDS
            aws ec2 wait instance-terminated --instance-ids $IDS
          else
            echo "No orphan Karpenter-tagged EC2 instances found."
          fi
```

A (Terraform-level) is the happy-path fix. B (workflow-level) is the safety net for broken-state recovery like this session. Both are needed: A alone doesn't protect against `terraform state rm` scenarios; B alone doesn't protect against the base race.

### Prevention

**Any Terraform resource that represents an *intent* for a controller to manage an external resource needs an explicit wait-for-actualization on destroy.** Karpenter's NodePool → EC2 is the obvious case; the same pattern applies to:

- ArgoCD Applications → in-cluster resources (handled via `finalizers: [resources-finalizer.argocd.argoproj.io]` in the Application spec — which this project already has on the root App)
- cert-manager Certificate → ACM / secret (when Phase 5 lands)
- External DNS → Route53 records

The general rule: **if a CRD is the Terraform-managed stand-in for an external resource, its destroy must wait for the controller to finish reconciling the deletion.** Either via built-in finalizers (ArgoCD), or via `kubectl wait` provisioners (Karpenter NodeClaim), or via a workflow-level sweep.

### Lessons

- **CRD deletion is asynchronous; Terraform's plan doesn't model the async tail.** Terraform sees "Kubernetes API accepted the delete" and moves on. Controllers process deletes over seconds-to-minutes; anything that depends on the external resource being truly gone (like subnet deletion) races with that tail.
- **`terraform state rm` is a legitimate recovery tool but has sharp consequences downstream.** In this session, removing the Karpenter resources from state to unblock Incident 18's teardown meant skipping the (already-racy) deprovision step entirely — the safety net that would have caught this was itself removed. The mitigation is the workflow-level sweep (B): a check that does not depend on Terraform state at all.
- **Belt-and-suspenders is the right architecture for teardown.** Single-point-of-failure in the destroy path is worse than a redundant extra check. The workflow-level sweep is cheap (one `describe-instances` call) and catches a class of errors Terraform cannot see.
- **Orphan EC2 = ongoing cost.** This EC2 ran for an extra ~15 min before discovery (~$0.0025 of Spot). Not a lot, but the PRINCIPLE matters: any "teardown finished" claim should be verifiable by cloud-provider APIs, not just by Terraform's exit code. Future teardown tooling should include a post-destroy sanity check that queries AWS for resources tagged to the cluster and errors if anything remains.

---

## Incident 20 — EKS auto-created cluster security group orphans the VPC on destroy

**Date**: 2026-04-14 (Phase 3c, second teardown attempt after Incident 19 fix)
**Severity**: S3 (teardown blocked again, different dependency this time; 30s manual SG delete + re-dispatch)
**Duration**: ~5 min to diagnose + one-line recovery

### Symptom

After Incident 19 was resolved (orphan EC2 manually terminated), the re-dispatched teardown progressed through workloads and platform destroy successfully, but then failed on the VPC itself:

```
Error: deleting EC2 VPC (vpc-05b22f3d2de81531c): operation error EC2:
  DeleteVpc, https response error StatusCode: 400,
  api error DependencyViolation: The vpc '...' has dependencies
  and cannot be deleted.
```

All the expected dependencies were clear: no ENIs, subnets all deleted, NAT Gateway `deleted`, no VPC endpoints, no IGW. `aws ec2 describe-security-groups --filters "Name=vpc-id,Values=..."` showed ONE non-default SG remaining: `sg-0738fa1d57f767219` named `eks-cluster-sg-aegis-staging-283648101`.

### Root cause

EKS auto-creates a **cluster security group** when a cluster is provisioned. This SG is used for control-plane-to-node traffic and is identified by the tag `aws:eks:cluster-name`. It is NOT managed by any Terraform resource in this project (or in most projects — it's an AWS-managed side effect of cluster creation).

AWS EKS is supposed to delete this SG when the cluster is deleted. In practice, this cleanup is eventual and can fail silently if:

- ENIs or Fargate tasks were still associated with the SG at cluster-delete time
- The cluster delete races with EKS's own cleanup job
- Some AWS-internal reconciliation window hasn't closed

When it fails, the SG is left behind tagged to a cluster that no longer exists. The VPC cannot be deleted because it contains a non-default SG. No Terraform resource owns the SG, so `terraform destroy` cannot clean it up either.

### Detection

`aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID"` immediately shows it — any non-default SG in a VPC that's supposed to be empty is the signal. The SG's name pattern (`eks-cluster-sg-<cluster-name>-*`) and tag `aws:eks:cluster-name` identify it as EKS-managed rather than user-defined.

### Resolution

**Immediate unblock** — manually delete the SG:

```bash
aws ec2 delete-security-group --region eu-central-1 \
  --group-id sg-0738fa1d57f767219
# Then re-dispatch teardown; VPC delete now proceeds.
```

**Codified in workflow** (so forkers never hit this):

A new pre-Terraform sweep step in the `destroy-network` job of `terraform-teardown-workload.yml`:

```yaml
- name: Sweep orphan EKS security groups in target VPC
  run: |
    VPC_ID=$(aws ec2 describe-vpcs \
      --filters "Name=tag:Name,Values=${{ inputs.env }}-vpc" \
      --query 'Vpcs[0].VpcId' --output text)
    if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
      SG_IDS=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" \
                  "Name=tag-key,Values=aws:eks:cluster-name" \
        --query 'SecurityGroups[].GroupId' --output text)
      for SG in $SG_IDS; do
        aws ec2 delete-security-group --group-id "$SG" || true
      done
    fi
```

Filter is deliberately narrow (`tag-key=aws:eks:cluster-name`): only EKS-auto-created SGs are targeted. User-defined SGs (if ever present in the staging VPC) are untouched. `|| true` on the delete — if the SG is actually still in use (shouldn't be, but defensive), we don't wedge teardown on it; Terraform will surface the DependencyViolation with better diagnostic context.

### Prevention

**Generalize: AWS services that auto-create VPC-scoped resources (SGs, ENIs, endpoints) are teardown hazards.** The pattern applies not just to EKS:

| Service | Auto-created resource | Tag / marker |
|---------|----------------------|--------------|
| EKS | Cluster SG | `aws:eks:cluster-name` |
| EKS Fargate | Fargate profile ENIs | (Terraform-managed via `aws_eks_fargate_profile`) |
| Lambda in VPC | Lambda hyperplane ENIs | `Interface Description: AWS Lambda VPC ENI-*` |
| ALB/NLB | LB SGs | LB tags |
| RDS (Aurora) | DB SGs | DB cluster tags |

Any teardown workflow that targets a VPC should include a pre-Terraform sweep for this class of resource, filtered by provider-specific tags.

In this project, the teardown workflow now sweeps:
- **Karpenter-provisioned EC2** (Incident 19) — `tag-key=karpenter.sh/nodepool`
- **EKS cluster SG** (Incident 20) — `tag-key=aws:eks:cluster-name`

When Phase 4+ adds new AWS-service-auto-created resources (GuardDuty detector ENIs, Security Hub agent SGs, Prometheus/AMP resources), extend the sweep accordingly.

### Lessons

- **AWS "managed" doesn't mean "cleaned up automatically on Terraform destroy".** The EKS cluster SG is managed by EKS control-plane, not by the `aws_eks_cluster` Terraform resource. When the cluster is destroyed, EKS is supposed to clean up — but this is an asynchronous, best-effort process from EKS's side. Terraform's view of the destroy is "the cluster resource is gone"; whether AWS followed through on side-effect cleanup is a separate concern.
- **Teardown pattern generalizes: service-specific orphan sweeps.** Incident 19 established the pattern for Karpenter-managed EC2. Incident 20 extends it to EKS-managed SGs. The same pattern will apply to future AWS services (cert-manager Route53 TXT records, VPC Lambda ENIs, ...). Future teardown hardening is additive along this axis.
- **`DependencyViolation` on VPC delete is a symptom, not a diagnosis.** The real question is always "what's the last thing in the VPC?" and `describe-network-interfaces`, `describe-security-groups`, `describe-vpc-endpoints`, `describe-subnets` one by one until something non-empty appears. For any VPC-teardown failure, this three-minute enumeration should be step 1.
- **Tag-based filtering is the right filter for auto-created orphan cleanup.** Not name patterns (names are controller-generated and change), not "everything except default" (risks user resources). Specific AWS-reserved tag keys (`aws:eks:cluster-name`, `aws:cloudformation:stack-name`, etc.) identify orphans precisely.

---

## Incident 21 — EKS Access Entry forbids `system:` prefix in `kubernetes_groups`

**Date**: 2026-04-14 (Phase 3c verification cold-apply attempt after Incident 15-20 codified)
**Severity**: S3 (blocked verification apply; Incident 18's fix was syntactically rejected)
**Duration**: ~5 min to diagnose + redesign

### Symptom

The `#3 verify Phase 3c` cold-rebuild apply (run 24402499456) failed mid-platform-apply:

```
Error: creating EKS Access Entry (aegis-***arn:aws:iam::251774439261:role/github-actions-terraform):
  InvalidParameterException: The kubernetes group name system:masters is invalid,
  it cannot start with system:

Error: creating EKS Access Entry (aegis-***arn:aws:iam::251774439261:role/aws-reserved/sso.amazonaws.com/eu-central-1/AWSReservedSSO_PlatformAdmin_*):
  InvalidParameterException: The kubernetes group name system:masters is invalid,
  it cannot start with system:

Error: Kubernetes cluster unreachable: the server has asked for the client to provide credentials
```

Both Access Entries rejected at create. Because the CI role's Access Entry couldn't be created, no Helm / kubectl resources downstream could authenticate either — the Helm provider errored `Kubernetes cluster unreachable`.

### Root cause

**Incident 18's fix was wrong.** I had changed `kubernetes_groups = []` → `kubernetes_groups = ["system:masters"]` on the assumption that binding the Access Entry to the built-in `system:masters` group would give the principal true Kubernetes cluster-admin (bypassing the `AmazonEKSClusterAdminPolicy` CRD-delete gap).

EKS Access Entry's API explicitly rejects group names starting with `system:`. This is documented in the AWS EKS API reference under the `kubernetes_groups` parameter constraints — but obscure enough to miss on a first read, and the rule only surfaces at CREATE time. In the session where Incident 18 was originally written, the Access Entries already existed; the `kubernetes_groups` change would have been applied as an UPDATE which went through a different code path that (apparently) did not enforce the `system:` check at the same validation layer.

On the verification cold-rebuild, the Access Entries were being created fresh — and the CREATE validator caught what the earlier UPDATE path had let through.

### Detection

The error message named the exact constraint (`it cannot start with system:`) and the exact value (`system:masters`). Unambiguous. A 30-second AWS docs search for "EKS Access Entry kubernetes_groups system:" confirmed the restriction.

### Resolution

**Redesign: custom group name + ClusterRoleBinding.** Instead of mapping principals to `system:masters` (rejected by EKS), map them to a custom group name (`aegis-cluster-admins`), then create a ClusterRoleBinding inside the cluster that binds that custom group to the built-in `cluster-admin` ClusterRole:

```hcl
# access-entries.tf (change in the ci + operator access_entry resources)
kubernetes_groups = ["aegis-cluster-admins"]  # was ["system:masters"]

# cluster-role-binding.tf (new file)
resource "kubectl_manifest" "aegis_cluster_admin_binding" {
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata = { name = "aegis-cluster-admins" ... }
    subjects = [{
      kind     = "Group"
      name     = "aegis-cluster-admins"
      apiGroup = "rbac.authorization.k8s.io"
    }]
    roleRef = {
      kind     = "ClusterRole"
      name     = "cluster-admin"
      apiGroup = "rbac.authorization.k8s.io"
    }
  })

  depends_on = [
    aws_eks_access_policy_association.ci_cluster_admin,
  ]
}
```

**Bootstrap chain is real.** On first apply:

1. Cluster + Access Entries + Access Policy Association created (AWS API — no cluster access needed)
2. `AmazonEKSClusterAdminPolicy` gives CI role the rights to create ClusterRoleBindings (create is in its scope; the gap was DELETE)
3. `kubectl_manifest.aegis_cluster_admin_binding` applies via CI's policy-granted rights
4. After the binding exists, CI's membership in `aegis-cluster-admins` confers true cluster-admin including CRD delete — closing the Incident 18 gap

**Destroy ordering is also real.** If Terraform destroyed the binding BEFORE the CRD kubectl_manifest resources (Karpenter NodePool, ArgoCD root Application), those deletes would fail because CI's effective permissions would drop back to policy-only (which has the CRD delete gap). To prevent this, every `helm_release` and CRD-installing `kubectl_manifest` that eventually deletes CRDs has `depends_on = [kubectl_manifest.aegis_cluster_admin_binding]`. Destroy reverses dependencies, so:

1. kubectl_manifest CRD resources destroyed (binding still alive → has cluster-admin → works)
2. helm_release resources destroyed (binding still alive → can clean up in-cluster objects)
3. binding destroyed
4. access_entries + policy_associations destroyed
5. cluster destroyed

Files modified:

- `access-entries.tf`: `kubernetes_groups` changed at both entries
- `cluster-role-binding.tf`: new file with the binding
- `karpenter-helm.tf`, `lb-controller.tf`, `argocd.tf`: added `depends_on = [kubectl_manifest.aegis_cluster_admin_binding]`
- CRD kubectl_manifest resources (NodePool, EC2NodeClass, argocd root app) get the dependency transitively via their helm_release dependency — no direct add needed

### Prevention

**AWS API constraints are enforced at CREATE but not always at UPDATE; the `system:` prefix rule is an example.** Future EKS Access Entry work should validate any `kubernetes_groups` value against the rule "must not start with `system:`" at the code-review stage. A pre-commit check or Terraform variable validation would catch this statically:

```hcl
variable "cluster_admin_group" {
  type    = string
  default = "aegis-cluster-admins"
  validation {
    condition     = !startswith(var.cluster_admin_group, "system:")
    error_message = "EKS Access Entry rejects group names starting with system:. See Incident 21."
  }
}
```

Not added to this project (single call site, easier to see inline), but the pattern transfers.

More generally: **when AWS documentation is obscure about a constraint that will surface at CREATE but not at UPDATE, assume the constraint exists even if your test didn't trip it.** My Incident 18 work tested against an existing cluster (UPDATE path). The verification cold-rebuild (CREATE path) caught the difference. The lesson is that real verification requires CREATE, not just UPDATE — which is exactly why `#3 verify Phase 3c` was worth the cost.

### Lessons

- **"Looked-right-in-code" ≠ "works-at-apply-time" for API parameters.** `system:masters` is a well-known Kubernetes built-in; intuition says it's a valid `kubernetes_groups` value. EKS Access Entry's API has its own validator, independent of Kubernetes's own group-name conventions. Trust the API's rejection message over intuition.
- **UPDATE and CREATE paths in cloud APIs sometimes enforce different rules.** This is a recurring pattern — not just EKS. Workaround: always test changes against a CREATE scenario, not just UPDATE on an existing resource. This is the single biggest argument for cold-rebuild verification as a portfolio practice.
- **Bootstrap chains: policy-association-for-bootstrap + binding-for-steady-state is a valid pattern.** Keep the policy association even when adding a binding — the policy is what lets the binding get created in the first place. Removing it creates a chicken-and-egg.
- **Transitive depends_on is often sufficient for destroy ordering.** I considered adding direct `depends_on = [kubectl_manifest.aegis_cluster_admin_binding]` on every CRD resource. Overkill: the CRDs already depend on their respective Helm releases which depend on the binding. The transitive chain ensures correct destroy order without duplication.

---

## Incident 22 — Karpenter controller killed mid-finalization by Fargate profile destroy

**Date**: 2026-04-14 (Phase 3c, teardown after full verify cold-rebuild — the one that followed Incident 21's fix)
**Severity**: S3 (teardown blocked; one more orphan EC2 + ENI + SG to clean manually; re-dispatch)
**Duration**: ~15 min to diagnose + manual cleanup + re-dispatch

### Symptom

After Incidents 15 – 21 were all codified and a full verification cold-rebuild apply succeeded, the subsequent teardown failed at `Destroy staging/network` — same symptom class as Incident 19, but a different instance:

```
Error: deleting EC2 Subnet (subnet-...): operation error EC2:
  DeleteSubnet, https response error StatusCode: 400,
  api error DependencyViolation: The subnet '...' has dependencies
  and cannot be deleted.
```

Orphan EC2 `i-0bd2d6d9d56f018b9` was still running, tagged `karpenter.sh/nodepool=default`. Its ENI was still attached; an orphan SG was also left. At first glance this looked like Incident 19 recurring — but Incident 19's workflow-level sweep (added in PR #56) should have caught it before Terraform even started. It didn't.

### Root cause

The orphan was created *during* Terraform's platform destroy, AFTER the pre-Terraform orphan-sweep step had already run (and correctly found nothing). The race is in the destroy ordering inside Terraform:

1. `kubectl_manifest.karpenter_default_nodepool` destroys — submits `kubectl delete nodepool default`, runs its local-exec `kubectl wait --for=delete nodeclaim` provisioner. **In CI, this provisioner is effectively a no-op**: the GitHub Actions runner was never configured with a kubeconfig (no `aws eks update-kubeconfig` step in the teardown workflow), so `kubectl` errors with "no current context" and the `|| true` tail swallows it. Incident 19's Part A defense was silently broken in CI.
2. Karpenter is still running on Fargate. It sees the NodePool deletion and begins draining NodeClaims, but that work is asynchronous and spans several minutes.
3. Terraform moves on to destroy `helm_release.karpenter`. The helm provider issues `helm uninstall`, which in turn submits a pod-delete API call to the Kubernetes API. **helm uninstall does not wait for pod termination** — `action.NewUninstall()` has `Wait = false` by default. The Terraform resource reports success as soon as the API accepts the delete.
4. Terraform sees `helm_release.karpenter` destroyed and parallelizes onward to `aws_eks_fargate_profile.karpenter` destroy. Fargate profile destroy forcefully kills all pods whose namespace selector matches — including the Karpenter controller pod that is still processing its graceful shutdown.
5. Any NodeClaim whose finalizer was *in flight* when the pod got killed is abandoned. Karpenter's CRD delete-reconcile loop doesn't resume (the controller is gone). The associated EC2 stays running, the ENI stays attached, the VPC cannot be torn down.

The Karpenter-manages-EC2 asynchronous tail (same class as Incident 19) meets the Fargate-profile-kills-pods synchronous cliff. The combination is what leaks the EC2.

This is a different failure mode from Incident 19 — there the cause was `terraform state rm` removing the drain logic from state entirely; here state was intact, but the drain-then-destroy sequence itself is racy when the drain step relies on kubectl being functional.

### Detection

Same as Incident 19: `DependencyViolation` from VPC destroy → `aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID"` finds the stuck ENI → `describe-instances` identifies the orphan EC2 → `describe-security-groups` finds the leaked cluster SG.

The tell that distinguished this from Incident 19 was timing: the pre-Terraform orphan sweep job had logged `::notice::No orphan Karpenter-tagged EC2 instances found.` — so the EC2 must have been created *after* that sweep ran, i.e., *during* the platform destroy. That ruled out any prior-state drift and pointed the investigation at in-destroy races.

### Resolution

**Immediate unblock** — manual cleanup of all three leaked resources:

```bash
export AWS_PROFILE=aegis-staging-admin
# 1. Terminate the orphan EC2
aws ec2 terminate-instances --region eu-central-1 --instance-ids i-0bd2d6d9d56f018b9
aws ec2 wait instance-terminated --region eu-central-1 --instance-ids i-0bd2d6d9d56f018b9
# 2. ENI is released automatically when instance is terminated (verify)
aws ec2 describe-network-interfaces --region eu-central-1 \
  --filters "Name=vpc-id,Values=$VPC_ID" --query 'NetworkInterfaces[].NetworkInterfaceId'
# 3. Delete the leaked cluster SG (same pattern as Incident 20)
aws ec2 delete-security-group --region eu-central-1 --group-id sg-...
# Re-dispatch teardown — network layer now destroys cleanly.
```

**Codified in Terraform + workflow** (belt-and-suspenders, covering both CI and local operator paths):

**A. Workflow-level Karpenter quiesce BEFORE `terraform destroy`** (`.github/workflows/terraform-teardown-workload.yml` → `destroy-platform` job):

A new step runs immediately after Terraform setup and before the existing orphan-EC2 sweep. It:

1. Fetches kubeconfig for the cluster (the step the workflow previously lacked — which is why Incident 19's local-exec provisioner was silently failing in CI).
2. Drains NodePools: `kubectl delete nodepool --all --timeout=10m` followed by `kubectl wait --for=delete nodeclaim --all --timeout=10m`. Karpenter, still running, processes these deletions gracefully — EC2s terminate.
3. Scales the Karpenter controller to 0 replicas: `kubectl scale deployment karpenter -n karpenter --replicas=0`, then `kubectl wait --for=delete pod -l app.kubernetes.io/name=karpenter`. After this, the controller is truly gone before Terraform touches anything, so the subsequent `helm uninstall` → `fargate_profile destroy` sequence has no pod to race against.

All commands tail `|| true` so a cluster-already-gone state doesn't wedge the workflow. The existing post-Terraform sweeps (Incidents 19 + 20) remain in place as final safety nets.

**B. Terraform-level NodePool destroy provisioner enhancement** (`terraform/environments/staging/platform/karpenter-nodepool.tf`):

Extend the existing local-exec from a single `kubectl wait` into a three-command sequence matching the workflow's quiesce logic. This path is what runs for local operators following runbook 002 — the kubectl auth is already present in their shell from `aws eks update-kubeconfig`.

```hcl
provisioner "local-exec" {
  when    = destroy
  command = <<-EOT
    kubectl wait --for=delete nodeclaim --all --timeout=10m || true
    kubectl scale deployment karpenter -n karpenter --replicas=0 || true
    kubectl wait --for=delete pod -l app.kubernetes.io/name=karpenter -n karpenter --timeout=5m || true
  EOT
}
```

The two fixes are complementary: (A) handles CI where kubeconfig is absent and kubectl provisioners are no-ops; (B) handles local operators where kubeconfig is present and the workflow doesn't run.

### Prevention

**Any resource that provisions external state via an asynchronous controller must be fully quiesced — not just told to stop — before the resource's host is destroyed.** Karpenter is one instance; the same applies to:

- cert-manager: scale controller to 0 before destroying ACM / Route53 DNS resources that its CRDs reference
- External-DNS: same pattern
- AWS Load Balancer Controller: scale to 0 before destroying the IAM role that its webhook uses, otherwise pending admission requests stall on bad auth
- Any operator that registers finalizers on non-Kubernetes resources

The general shape of the fix is: **(delete intent → wait for reconciliation → scale controller to 0 → wait for controller gone) must be ONE atomic sequence before anything the controller depends on is destroyed.**

This is the teardown-side complement to the "wait for webhook endpoints to exist before installing the next chart" pattern from Incident 17 — in both cases, Kubernetes's async-reconcile model doesn't fit Terraform's declarative plan without explicit synchronization.

**Sub-rule: provisioners that depend on kubectl need an explicit kubectl setup step in every execution environment.** The local-exec provisioner on the NodePool was added for Incident 19 and tested locally (where `aws eks update-kubeconfig` had been run during session start) — it worked there. It was never validated in CI, where the workflow had no equivalent setup. The pattern generalizes: any Terraform feature that assumes a tool is configured needs a test path through the actual execution environment, not just the operator's local shell.

### Lessons

- **"Fix works locally" ≠ "fix works in CI".** Incident 19's local-exec provisioner solution was validated on the operator's machine and merged. The CI-side regression was invisible because `|| true` converts a fatal kubectl error into a silent no-op. The generalizable rule: defensive error-swallowing hides environment-specific breakage. Either (a) remove the `|| true` and accept that destroys must be resumable when kubectl is misconfigured, or (b) keep `|| true` but require a separate CI-environment validation. This project chose (b) via the workflow-level quiesce step — which does not depend on the provisioner running.
- **helm uninstall is asynchronous.** `helm_release`'s Terraform resource reports destruction complete as soon as the Kubernetes API accepts the manifest deletes, NOT when pods have actually terminated. Anything that expects "pod gone by now" after helm_release destroys is making an assumption the resource does not guarantee. The fix is always to add explicit pod-wait, not to expect helm to wait on your behalf.
- **Fargate profile destroy is a hard cliff.** Unlike deleting a Deployment (which triggers graceful pod termination with `terminationGracePeriodSeconds`), deleting a Fargate profile effectively force-kills every pod whose namespace selector matched. There is no "drain" semantic on Fargate. Any controller running on Fargate must be scaled to 0 explicitly before its Fargate profile is destroyed — you cannot rely on normal graceful shutdown.
- **Belt-and-suspenders is the right teardown architecture.** Three layers now protect against this class of leak: (1) Terraform NodePool destroy provisioner; (2) workflow-level Karpenter quiesce step; (3) workflow-level post-sweep for orphan EC2 and SGs. Each covers cases the others miss. This is more code than a single "correct" fix, but single-point-of-failure in destroy is worse than redundancy — the cost of a missed orphan is paid in dollars per hour and operator time.
- **Asymmetric dependency reversal is not a fix for destroy-order races.** My initial instinct (recorded the night before) was "add `depends_on = [helm_release.karpenter]` to the Fargate profile so Fargate destroys last." This creates a plan-time cycle with the existing dependency in the opposite direction — which is load-bearing for CREATE order (Fargate must exist before Helm's pods can be admitted). You cannot change destroy order by flipping depends_on without also breaking create order; Terraform uses the same graph for both. The correct fix is an explicit quiesce step that runs as part of one of the destroys, not a graph reshape.

---

## Incident 23 — Dependabot PR plans silently fail because secrets live in a separate namespace

**Date**: 2026-04-15 (post-Phase-3c, routine Dependabot sweep)
**Severity**: S4 (CI-only; no AWS impact, no cost exposure)
**Duration**: ~30 min (first failing PR seen → fix verified green)

### Symptom

All 11 open Dependabot PRs (3 recent GitHub Actions version bumps + AWS provider v5→v6 across 6 Terraservices + 2 checkout/credentials bumps) fail the required `Terraform Plan` status check. Every matrix leg (`management/bootstrap`, `management/scps`, `shared/bootstrap`, `shared/ipam`, `staging/bootstrap`, `staging/network`) reports the same result.

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
# (separate store by design; see docs/incidents.md §23)
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

## Incident 24 — Terraform plan stampede fails on S3 native state lock under Dependabot bulk rebase

**Date**: 2026-04-15 (same session as Incident 23; discovered while verifying the Incident 23 fix)
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

1. First wave (Incident 23): `yamldecode: missing start of document` — six legs × multiple PRs.
2. After fixing the Dependabot secret and verifying `codeql-action` went 6/6 green, I bulk-reran the other nine with `gh run rerun --failed`. Same matrix-wide failure pattern, but error text changed to `Error acquiring the state lock`. Different symptom, different root cause. Same shape (all-legs failure across all PRs) because both causes are environmental, not code-specific.

General rule for bisection: **matrix-wide failure across unrelated PRs is always environmental.** The question is only which part of the environment — secrets, state, permissions, quota, external dependency. When one of those is ruled out, work down the list.

### Resolution

**Preventive fix to the plan workflow.** Adding `-lock-timeout=10m` to the plan command (`.github/workflows/terraform-plan.yml`) lets each planner wait up to 10 min for the lock instead of failing instantly. Under Dependabot stampede, the ten runs serialize: each plan takes ~30 s, so the last one in the queue waits ~5 min — well inside the timeout. In the no-contention case (normal human PR), the flag is a no-op.

```diff
-        run: terraform plan -no-color -input=false -detailed-exitcode
+        run: terraform plan -no-color -input=false -detailed-exitcode -lock-timeout=10m
```

Not applied to `terraform-apply-*.yml` and `terraform-teardown-workload.yml` in this incident's fix, because:

- Apply and destroy are always gated behind explicit `workflow_dispatch` + GitHub Environment approval. There is no scenario where ten applies race for the same state file.
- A stuck state lock on apply/destroy is a real operational signal the operator should see quickly (someone killed a previous run, `force-unlock` may be needed). Masking that with a generous timeout would hurt, not help.

If a future session shows apply-side contention, the flag can be added there too — tracked as "apply lock-timeout" follow-up, but not done now (YAGNI).

**Operational correction**: the nine failed PRs can be re-driven either by another `@dependabot rebase` (now safe — lock-timeout makes the stampede self-serializing) or by waiting for Dependabot's next poll which rebases onto the lock-timeout-fixed main.

### Prevention

- **Workflow-level**: `-lock-timeout=10m` on plan, as above. Eliminates this class of failure for any future concurrent-PR scenario (Dependabot, multiple humans reviewing different PRs, CI rerun loops).
- **Operator-level**: when bulk-operating on Dependabot PRs (or any action that triggers many workflows at once), space the triggers OR rely on downstream serialization. Posting ten `@dependabot rebase` comments with a `sleep 2` in a loop is **not** spacing — GitHub and Dependabot will happily process them faster than the Terraform back-end can serialize plans. If you find yourself writing a `for` loop that triggers workflows, prefer `until`-loop polling that waits for the previous run to finish before starting the next.
- **No new `configure-*.sh` change.** The script sets secrets, not timeouts. Timeouts are CI config, correctly located in the workflow.

### Lessons

- **`use_lockfile = true` (S3 native locking) is strictly first-come-first-served with no queue.** The choice to drop DynamoDB (ADR-003) is correct for this project — DynamoDB's lease-based locking had the same "no queue, fails fast" semantics anyway — but it means explicit `-lock-timeout` on every Terraform CLI invocation in CI is the *only* defense against concurrent-plan failure. It is not optional for a repo that uses matrix plans AND expects multiple PRs open simultaneously.

- **"Plan is read-only" is a mental model trap.** Plan writes a state lockfile. Plan writes a plan file if `-out` is used. Plan may refresh remote state and rewrite it (until `-refresh=false`). Anything about plan that assumes "no side effects" is wrong at the infrastructure boundary, even if the Terraform resources themselves are untouched. The practical consequence: any CI orchestration that assumes "plans are fine to run in parallel" needs lock-timeout, not just "I thought plan was read-only."

- **Two incidents in one session with identical symptoms but different root causes is a pattern, not a coincidence.** Both Incident 23 and 24 presented as "matrix-wide Plan failure across all six Terraservice layers and all Dependabot PRs." Different errors, same shape. When the second wave appeared, the shape of the failure ruled out code-level bugs (different provider versions, different GitHub Action bumps) and pointed at environment. That shape-based filter is worth remembering as a first-cut triage tool — *if every leg fails the same way across unrelated PRs, look outside the code.*

- **Operator batching + bot batching = quadratic pressure on shared-state systems.** I issued ten rebase comments with a 2-second gap. Dependabot consumed them in parallel. Ten PRs × six matrix legs = sixty plan invocations against six state files, arriving within ~10 seconds. This is not a theoretical edge case — it is what happens every time a batch of Dependabot PRs gets rebased simultaneously after a main-branch update. `-lock-timeout` is the generic answer. The more specific answer is: **don't batch-trigger bot workflows from the command line.** Either `@dependabot rebase` one-by-one as each preceding PR lands, or let Dependabot's own cadence handle it.

---

## Incident 25 — ECR repository policy rejected at apply time despite clean plan (principal shorthand + resource-field ambiguity)

### Symptom

A PR (#86 / commit `e4e…`, closing cross-repo issue #83) added an `aws_ecr_repository_policy` to the `aegis-core` ECR repo. `terraform plan` in CI was clean — "Plan: 1 to add, 0 to change, 0 to destroy." After merge to main, `terraform-apply-baseline.yml` → job `Apply staging/bootstrap` failed with:

```
Error: putting ECR Repository Policy (aegis-core): operation error ECR:
SetRepositoryPolicy, https response error StatusCode: 400, ... InvalidParameterException:
Invalid parameter at 'PolicyText' failed to satisfy constraint: 'Invalid repository policy provided'
```

Other baseline jobs (management/bootstrap, management/scps, shared/bootstrap, shared/ipam) all succeeded — only the ECR-touching layer failed. Baseline run: 24629024427. Full log: job 72013019050.

### Root cause

Three defects in the policy document shape, each independently enough to trip ECR's `ValidatePolicy` API call. Terraform's plan step does no server-side validation for resource-policy fields — it just serializes the HCL into a JSON blob and sends it at apply time. That is why plan was green.

1. **`Principal = "*"` — shorthand not accepted by ECR repository policies.** The IAM identity-policy spec allows `"Principal": "*"` as a shortcut for `{ "AWS": "*" }`, and many AWS services accept it in resource policies. ECR does not. It requires the explicit `{ "AWS": "*" }` form. This is ECR-specific strictness — the same shorthand works on S3 bucket policies, KMS key policies, and IAM role trust policies without complaint.

2. **`Resource = "*"` in a repository-scoped policy.** ECR repository policies are attached to a specific repository; the resource is implicit. Including an explicit `Resource` field, even `"*"`, makes ECR interpret the policy as trying to cover multiple resources across the account — which is not a thing repository policies can do. The fix is to omit the field entirely.

3. **`ecr:BatchCheckLayerAvailability` included in the deny list.** Functionally wrong, not a policy-validity issue in isolation but worth pairing in the same fix: `BatchCheckLayerAvailability` is called on the pull path *and* the push path. Denying it for non-OIDC principals would have broken pulls from Karpenter EC2 nodes (pulling the engine image to schedule pods), ArgoCD (pulling to validate manifest references), and every future Cosign/Trivy consumer. The four remaining actions — `PutImage`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload` — are push-only and sufficient to block `docker push` from any non-OIDC identity.

### Detection

`gh run view 24629024427 -R … --log-failed | grep -B1 -A10 'Error:'` surfaced the AWS-side validation error. The error message is generic ("Invalid repository policy provided") — AWS does not tell you *which* field failed. Debugging required diffing the written policy against a known-working ECR policy from the HashiCorp AWS provider examples.

### Resolution

PR #87 with three changes, each with inline comments documenting the quirk:

```hcl
resource "aws_ecr_repository_policy" "aegis_core_push_restriction" {
  repository = aws_ecr_repository.aegis_core.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyPushExceptFromOIDCRole"
      Effect = "Deny"
      Principal = {
        AWS = "*"                                      # (1) explicit form, not "*"
      }
      Action = [
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",                     # (3) BatchCheckLayerAvailability removed
      ]
                                                       # (2) Resource field omitted
      Condition = {
        StringNotEquals = {
          "aws:PrincipalArn" = aws_iam_role.aegis_core_ecr.arn
        }
      }
    }]
  })
}
```

Verified with a local `terraform apply` against live state before committing. Plan delta: `Plan: 1 to add, 0 to change, 0 to destroy.` — same shape as the failing PR, but this time apply succeeds.

### Prevention

- **For any new AWS resource-policy resource (S3 bucket policy, KMS key policy, SQS/SNS queue policy, ECR repository policy, etc.): test the policy with a throwaway local apply before committing.** `terraform plan` validates Terraform-side schema but cannot catch service-specific policy-document rejection. The round-trip is ~10 seconds; the cost of a failed baseline apply and a fix-forward PR is ~20 minutes. Always cheaper to apply locally first.

- **Do not carry shorthand IAM forms across service boundaries.** `Principal = "*"` works for S3/IAM/KMS but not ECR. `Resource = "*"` has different semantics across services (global vs. resource-implicit vs. repository-scoped). When writing a resource policy for a service you have not touched before, start from the AWS documentation's canonical example for that service, not from a copied IAM policy that happens to look similar.

- **Read action lists by their use path, not their name.** `BatchCheckLayerAvailability` *sounds* like a push action because layer existence is checked during push. It is also called during pull to detect missing layers. Any name that looks push-only or pull-only in ECR's action list deserves a quick "is it used by both paths?" check before putting it into a Deny statement. The AWS ECR IAM reference documents which actions are on which path; the action name alone is not a guide.

### Lessons

- **Clean plan ≠ apply will succeed** for resource-policy resources. This is structural in Terraform: plan is a dry run that cannot validate opaque document fields (IAM policy JSON, Lambda function code, CloudFormation templates embedded as strings, etc.). Treat every resource whose state-changing field is a blob as "plan is necessary but not sufficient."

- **Defense-in-depth work needs a fire drill step.** The whole point of the ECR resource policy is to block a hypothetical attack path that has never been exercised. The first time it will be exercised is when something legitimate accidentally trips it — e.g. a future Cosign integration that pushes signatures as OCI artifacts. When this happens, the operator should already have the mental model "this is the policy that denied me, here is the ARN condition, here is how to add a new allowed principal." The inline comments in the Terraform resource carry that forward; so does this incident entry.

- **Baseline apply failures on merge are the most painful class of failure.** They fire post-merge, so the PR is already closed; the only recourse is a fix-forward PR. Plan-time validation matrices in CI are the correct forum for blob validation once the pattern is identified — e.g. an opa/conftest check on ECR policy JSON shape would have caught all three defects at PR time. Worth revisiting if a second "plan green but apply fails on a resource-policy blob" incident appears.

---

## Incident 26 — Kyverno ClusterPolicy apply fails on cold apply: ArgoCD-managed chart not yet synced

**Date**: 2026-04-20 (Session C first cold-apply after workloads slot-pattern refactor, PR #100)
**Severity**: S2 (blocks `terraform apply` on the workloads layer; recoverable via retry)
**Duration**: ~2 minutes to diagnose + ~4 minutes for retry apply to succeed

### Symptom

Fresh `gh workflow run terraform-apply-workload.yml -f env=staging` (both `eks.staging.regions` slots) failed in the `Apply staging/workloads` job with identical errors against both `module.workloads_primary` and `module.workloads_slave_1[0]`:

```
Error: require-app-labels failed to create kubernetes rest client for update
  of resource: resource [kyverno.io/v1/ClusterPolicy] isn't valid for
  cluster, check the APIVersion and Kind fields are valid
  with module.workloads_<slot>.kubectl_manifest.policy_require_labels,
  on modules/eks-workloads/kyverno.tf line 243
```

Other earlier-in-module resources succeeded (namespace, NetworkPolicies, IRSA, GuardDuty detector+features, random_password, both ArgoCD Applications for kyverno + kube-prometheus-stack). Only the four `kubectl_manifest.policy_*` resources failed, in both slots.

### Root cause

Bootstrap race. `modules/eks-workloads/kyverno.tf` installs Kyverno **via an ArgoCD Application** (created by `kubectl_manifest "kyverno"`), not via `helm_release`. The four `kubectl_manifest.policy_*` resources have `depends_on = [kubectl_manifest.kyverno]`, which satisfies Terraform's dependency graph as soon as the Application CRD exists in etcd — but the Kyverno Helm chart itself (which ships the `ClusterPolicy` CRD) is asynchronously synced by the ArgoCD application-controller afterwards.

Between "Application CRD exists" and "ArgoCD has actually installed the chart" is a ~1–3 minute window where the `ClusterPolicy` CRD does not exist in the cluster. Terraform's `kubectl_manifest` tries to apply the `ClusterPolicy` resource during this window, which maps to an API call that the K8s API server rejects with "resource not valid for cluster".

The comment block in `kyverno.tf` claimed "the kubectl provider's deferred plan-time schema validation handles this bootstrap ordering — same pattern as Karpenter NodePool". That analogy is wrong: Karpenter NodePool works because Karpenter is installed via `helm_release` in `staging/platform/karpenter-helm.tf`, which is a **synchronous** install that blocks Terraform until the Helm release reports ready — and the CRDs are part of that release. Kyverno here is installed via ArgoCD Application, which is **asynchronous** with respect to Terraform. The `depends_on` only waits for Terraform's own resource, not for ArgoCD to finish its job.

This race was present since the original workloads layer (PR #68, Phase 4c) but likely never triggered before Session C because: (a) earlier applies may have happened to hit lucky timing, or (b) the workloads layer was never cold-applied after a clean teardown — prior sessions kept state long enough for the CRD to persist across apply attempts, so the race was masked. Session C is the first clean cold apply of the workloads layer ever attempted.

### Detection

Workflow job output showed the error message above for both slots. `kubectl --context primary get crd | grep kyverno` confirmed that at the time the apply retried a few minutes later, all Kyverno CRDs (`cleanuppolicies`, `clusterpolicies`, etc.) did exist — further evidence that the failure was purely timing-based, not configuration-based.

### Resolution

Retry: `gh workflow run terraform-apply-workload.yml -f env=staging` a second time, with the same approval. By the time the retry reaches the `kubectl_manifest.policy_*` resources, ArgoCD has already synced the chart and the CRDs are present. The policies apply cleanly. Network + Platform jobs replan to "0 changes" and pass quickly.

No state cleanup needed — the failing apply left no partial state for `policy_*` (they were never created server-side), so retry creates them normally.

### Prevention

Two fixes, one substantive, one lightweight:

1. **(Preferred) Convert Kyverno from ArgoCD Application to `helm_release`** in `modules/eks-workloads/kyverno.tf`. Same pattern as Karpenter / LB Controller in `staging/platform/`. `helm_release` is synchronous by default (`wait = true`), blocks Terraform until the release reports ready, and the `ClusterPolicy` CRD exists after that. Then `kubectl_manifest.policy_*` can reliably apply. Loses the ArgoCD-visible lifecycle for Kyverno itself; the `ClusterPolicy` resources can optionally move to a separate ArgoCD Application after the chart is up. Tradeoff explicit.

2. **(Lightweight band-aid) Add a `time_sleep` resource** between `kubectl_manifest.kyverno` and `kubectl_manifest.policy_*`:

   ```hcl
   resource "time_sleep" "wait_for_kyverno_sync" {
     depends_on      = [kubectl_manifest.kyverno]
     create_duration = "180s"
   }
   ```

   Then each policy does `depends_on = [time_sleep.wait_for_kyverno_sync]`. This is a fragile fix — 180s is a guess, and slower ArgoCD sync on overloaded clusters will still race. Acceptable as a stopgap; not as a final fix.

3. **Correct the comment block in `kyverno.tf`** that claimed the kubectl provider's deferred schema validation handles this. It does not; that claim misled the original author and nearly anyone reading the file. Incident-driven documentation pass on this layer is due.

The same race applies to `kubectl_manifest.kube_prometheus_stack` in `observability.tf` — it also creates an ArgoCD Application, and if any downstream Terraform resource tried to use a kube-prometheus-stack CRD it would hit the same pattern. None do today; the observability Application is terminal in the module. Not yet a bug; flag for future additions.

### Lessons

- **`depends_on` between `kubectl_manifest` + ArgoCD Application is not a real ordering guarantee for anything the Application creates downstream.** The `kubectl_manifest` resource completes as soon as the CRD is in etcd; the Application's own work is asynchronous. If a subsequent Terraform resource requires what the Application creates (CRDs from the chart, namespace objects, webhooks, etc.), the correct tools are either synchronous `helm_release` or `time_sleep` + retry, not `depends_on`.

- **Analogies between "similar patterns in different layers" can be wrong in load-bearing ways.** The Karpenter-NodePool analogy sounded identical but was actually a `helm_release` vs `ArgoCD Application` distinction that carried all the weight. Future patterns derived by analogy should explicitly check the sync semantics of the referenced base pattern, not just the surface shape.

- **Cold-apply testing is load-bearing for first-time assembly.** This bug was structurally always present but never hit because workloads had not been cold-applied against empty state before. Every multi-layer Terraform system accumulates "works if state persists" assumptions that a clean teardown / reapply cycle will expose. Session-C-style full-stack clean applies should be a regular fire drill, not a portfolio-only one-off.

- **The ArgoCD-managed vs Terraform-managed lifecycle for platform dependencies is a recurring design axis.** ADR-015 and ADR-016 both put operator Apps (kube-prometheus-stack, Kyverno) into ArgoCD for lifecycle visibility. But when Terraform needs synchronous handoff (CRDs must exist before a downstream TF resource runs), ArgoCD's async model breaks the handoff. Worth adding to ADR-015 / ADR-016's "Consequences" section as a known tradeoff; candidate future ADR if the pattern recurs.

---

## Incident 27 — kube-prometheus-stack node-exporter DaemonSet stays Pending on Fargate nodes

**Date**: 2026-04-20 (Session C verification after workloads layer apply, PR #100)
**Severity**: S3 (observability partially degraded — node-exporter missing on Fargate-scheduled nodes; cluster still functional)
**Duration**: Present on every apply of the workloads layer since Phase 4c; first noticed during Session C

### Symptom

After `staging/workloads` applies, `kubectl get pods -A` on each cluster shows:

```
monitoring   kube-prometheus-stack-prometheus-node-exporter-wpl7l   0/1   Pending   0   4m30s
```

`kubectl describe` on the Pending pod surfaces scheduling refusal — the pod tolerates taints but cannot be scheduled on Fargate nodes (EKS Fargate does not support `DaemonSet` pods; it is one-pod-one-microVM and ignores DaemonSet scheduler intent).

In both slots (primary + slave_1) the cluster has 3 Fargate nodes (CoreDNS × 2 + Karpenter controller) and 2 EC2 nodes (Karpenter-provisioned). node-exporter schedules successfully on the 2 EC2 nodes but leaves 1 pod Pending per Fargate node, because the DaemonSet controller keeps trying.

### Root cause

The kube-prometheus-stack Helm chart's `prometheus-node-exporter` sub-chart does not exclude Fargate by default. Its `nodeSelector` / `affinity` / `tolerations` are tuned for standard Kubernetes clusters where every node is capable of running a DaemonSet; on EKS Fargate, the DaemonSet controller schedules a pod per node regardless, and Fargate silently fails to admit it.

The values in `modules/eks-workloads/observability.tf` do not override this. Upstream chart maintainers know about this and the [kube-prometheus-stack README](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) suggests an affinity override for EKS:

```yaml
prometheus-node-exporter:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: eks.amazonaws.com/compute-type
                operator: NotIn
                values: [fargate]
```

Our chart values do not yet include this stanza, so the DaemonSet includes Fargate nodes in its scheduling set. Fargate refuses. Pods go Pending.

### Detection

Runbook 003 §9 pod sweep during Session C verification:

```bash
kubectl --context primary get pods -A | grep -vE "Running|Completed"
```

Turned up two Pending node-exporter pods (one per Fargate node) per cluster. The crashing pods aged ~4–5 minutes at verification time, matching the monitoring Application's sync lifecycle.

### Resolution

During the session: no action. Partial-coverage node-exporter is better than nothing (EC2 nodes, which carry the actual workload pods, DO get metrics). Functional impact is zero for the failover demo and portfolio narrative.

Long-term fix (next workloads-layer PR): add to `modules/eks-workloads/observability.tf` inside the `kube-prometheus-stack` Helm values:

```yaml
"prometheus-node-exporter" = {
  affinity = {
    nodeAffinity = {
      requiredDuringSchedulingIgnoredDuringExecution = {
        nodeSelectorTerms = [{
          matchExpressions = [{
            key      = "eks.amazonaws.com/compute-type"
            operator = "NotIn"
            values   = ["fargate"]
          }]
        }]
      }
    }
  }
}
```

### Prevention

- **When installing Helm charts that ship DaemonSets onto EKS Fargate-mixed clusters, review the chart's Fargate affinity stance up front.** kube-prometheus-stack, fluentd, falco, others all ship DaemonSets. EKS Fargate excludes them silently. Default chart values assume homogeneous nodes; EKS mixed compute needs affinity overrides.

- **Make node-exporter coverage explicit in observability posture docs.** `docs/decisions/015-observability-tooling.md` should note that EC2-only node-exporter coverage is accepted for EKS Fargate-mixed clusters. Without the doc, an operator three months from now will diagnose "why are half my node_exporter pods Pending" as a new incident rather than recognize it as established behavior.

### Lessons

- **EKS Fargate DaemonSet refusal is silent and persistent.** Unlike a `NodeAffinity` mismatch (which produces a clear `Unschedulable` event), a Fargate-mode refusal of a DaemonSet pod looks like vanilla `Pending` + pod age grows. Easy to miss in a quick pod sweep; only shows up if the operator knows to look for it.

- **Chart defaults are tuned for non-EKS clusters.** Most Helm charts in the Prometheus / Grafana / OpenTelemetry ecosystems assume vanilla K8s where every node is a peer. EKS Fargate-mixed clusters are a nontrivially different topology. When adopting an upstream chart on EKS mixed, budget an affinity / tolerations pass *before* first apply.

---

## Incident 28 — GuardDuty EKS Runtime Monitoring agent DaemonSet CrashLoopBackOff on both clusters

**Date**: 2026-04-20 (Session C verification after workloads layer apply with GuardDuty `EKS_RUNTIME_MONITORING` feature enabled, PR #100)
**Severity**: S2 (security posture degraded — runtime threat detection not active; cluster functional; GuardDuty _audit log_ monitoring still works)
**Duration**: Unresolved at session close. Deferred to a diagnose-and-fix PR in the next session.

### Symptom

After `staging/workloads` applies, each cluster shows the GuardDuty managed addon's DaemonSet pods failing in the `amazon-guardduty` namespace:

```
amazon-guardduty   aws-guardduty-agent-k2xn6   0/1   CrashLoopBackOff   6 (21s ago)   6m21s
amazon-guardduty   aws-guardduty-agent-tm2zz   0/1   Pending            0             6m21s
```

Same pattern on both primary (eu-central-1) and slave_1 (eu-west-1). Restart counts climb; the pods never reach Running.

The pods are created by the GuardDuty-managed EKS addon that the `aws_guardduty_detector_feature.eks_runtime` resource with `additional_configuration { name = "EKS_ADDON_MANAGEMENT"; status = "ENABLED" }` installs. That addon includes a DaemonSet for runtime monitoring.

### Root cause

**Not fully diagnosed at session close.** Candidate causes, in decreasing likelihood:

1. The addon DaemonSet tries to schedule on Fargate nodes (same failure mode as Incident 27 for node-exporter) — and additionally needs node-level access (eBPF, `/sys`, `/proc`) that Fargate forbids. Partial Pending (1 pod per Fargate node) and partial CrashLoopBackOff (on EC2 nodes for a different reason) would fit this split signature.
2. The EC2 node instance profile / Karpenter NodeClass IAM role lacks the specific GuardDuty runtime agent permissions. The agent needs to call `GuardDuty:*` back to the detector.
3. A specific EC2 node configuration (kernel version, AMI type) is incompatible with the runtime agent's eBPF program requirements. The current Karpenter NodePool uses AL2023 by default; the runtime agent historically required specific minimum AL2/AL2023 patches.

The CrashLoopBackOff on EC2 nodes and Pending on Fargate nodes suggests a *combination* of #1 and #2 or #3.

### Detection

Runbook 003 §9 pod sweep during Session C verification. `kubectl get pods -A | grep -vE "Running|Completed"` surfaced the failing pods on both clusters; same pattern on both.

Did not dive into `kubectl describe` / `kubectl logs` during the session — teardown was prioritized over per-pod diagnosis to cap AWS spend. The container logs are captured in the earlier `gh run view` output from the failed workflow run; those logs may still be retrievable from the pods before teardown drops the cluster.

### Resolution

During the session: none. Runtime threat detection is a nice-to-have; audit log monitoring (the other GuardDuty EKS feature enabled in the same resource) continues to work. Functional impact on Session C's portfolio goal is zero — slot pattern validation does not depend on GuardDuty agent health.

Tracked for a dedicated diagnose-and-fix PR in the next session. Scope:

1. Reproduce the failure on a single-region apply (simpler environment; less cost).
2. `kubectl -n amazon-guardduty describe pod aws-guardduty-agent-<id>` to classify: scheduling reason (affinity, resources) vs runtime error (init container exit, main container crash).
3. `kubectl -n amazon-guardduty logs aws-guardduty-agent-<id> --previous` for the CrashLoopBackOff pods.
4. Cross-reference [AWS GuardDuty EKS Runtime Monitoring troubleshooting](https://docs.aws.amazon.com/guardduty/latest/ug/runtime-monitoring-troubleshooting.html) for the specific failure signature.
5. Apply the fix (likely: Fargate exclusion via `nodeSelector` override on the addon configuration, or an IAM policy attached to the Karpenter node role).

### Prevention

- **For any AWS-managed EKS addon, include a day-one smoke check** that the addon's DaemonSet (if any) actually reaches Running on all expected nodes. `kubectl -n <addon-ns> get pods -o wide` as part of post-apply verification would have surfaced this on the first Phase 4c apply, not 48 hours later during Session C.

- **Add an improvements entry** (`010-guardduty-runtime-agent-fargate-compat.md` or similar) once the root cause is known. Tracking the fix as a deliberate improvements item makes the DR story clearer — GuardDuty EKS Runtime Monitoring is *enabled* in the Terraform but *not effective* at lab tier; that is a known gap, not a silent failure.

### Lessons

- **"Enabled via Terraform" ≠ "operationally effective"** for AWS-managed addons whose effectiveness depends on in-cluster workload health. The `aws_guardduty_detector_feature` resource went green (AWS-side enable succeeded). The in-cluster DaemonSet is a separate failure surface that Terraform has no visibility into.

- **Same Fargate DaemonSet trap as Incident 27, different vendor.** The EKS Fargate limitation ("no DaemonSet pods") bites AWS-managed addons the same way it bites upstream Helm charts. Worth adding a one-line check to `docs/decisions/013-eks-architecture.md` Consequences: "Any DaemonSet in the cluster must be configured to skip Fargate nodes."

---

## Incident 29 — ArgoCD application-controller OOMKilled on primary cluster under cold-start reconcile

**Date**: 2026-04-20 (Session C verification, PR #100 workloads slot-pattern refactor; primary cluster only)
**Severity**: S2 (primary cluster's GitOps loop degraded; slave_1 fine; manual intervention required for the ArgoCD UI to be usable on primary)
**Duration**: Observed mid-session; not resolved in-session (teardown followed immediately).

### Symptom

In the primary cluster (`eu-central-1`) only, `argocd-application-controller-0` enters `CrashLoopBackOff` with Exit Code 137 within ~2 minutes of ArgoCD's first cold sync:

```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

Restart count climbed to 5 within ~8 minutes of cluster bring-up. Slave_1's `argocd-application-controller-0` stayed `Running 1/1` throughout the session with zero restarts despite the same chart version, same Helm values, same cluster size, same list of ArgoCD Applications (`kube-prometheus-stack`, `kyverno`, `root`).

### Root cause

Default ArgoCD Helm chart memory limits are too low for cold-start reconciliation when the controller has to simultaneously:

- Parse the 3 ArgoCD Applications' manifests
- Compare each against live cluster state
- Reconcile each — which for `kube-prometheus-stack` means pulling a ~300 MB Helm chart, rendering it, and diff-ing against ~30+ in-cluster objects

The memory peak during this phase exceeds the chart default. After steady state (applications Synced, reconcile loop becomes incremental), memory drops back to well below limit — so the pod stays Running on slave_1 where the bring-up sequence was slightly staggered (slave cluster came up seconds after primary; by the time primary was in reconcile peak, slave was still in `apps-being-registered` phase, then by the time slave hit reconcile peak, primary's earlier crashes had prompted slave to spread the work over more time).

The asymmetric behavior is load-ordering dependent: whichever cluster hits the reconcile storm first, peaks higher. Not a slot-pattern bug — it would affect a single-cluster deploy the same way, it just hasn't been load-tested against cold-start memory.

### Detection

Runbook 003 §9 ArgoCD pod health check:

```bash
kubectl --context primary -n argocd get pods --no-headers | awk '{print $1, $2, $3}'
```

Showed `argocd-application-controller-0 0/1 CrashLoopBackOff`. `kubectl describe pod` confirmed `OOMKilled`:

```bash
kubectl --context primary -n argocd describe pod argocd-application-controller-0 | grep -A3 "Last State:"
```

Exit code 137 = SIGKILL from OOM killer.

### Resolution

During session: none — taking the controller out of the OOM loop would require editing the StatefulSet in place, which is beyond the scope of a verification-only session. The cluster was functional enough for verification (other ArgoCD components running; applications visible; reconcile just delayed/intermittent).

Long-term fix (next workloads-layer PR or platform-layer PR — depends on where ArgoCD chart values are set; check `staging/platform/argocd.tf`):

```yaml
controller:
  resources:
    limits:
      memory: 1Gi    # up from chart default (typically 256Mi–512Mi)
    requests:
      memory: 512Mi
```

Alternate: enable ArgoCD controller sharding (`replicas: 2`, shard assignment via `ARGOCD_CONTROLLER_SHARD`) so load distributes across more pods. Shards per-cluster is overkill for a lab but matches production ArgoCD deployments.

### Prevention

- **Size ArgoCD controller memory for cold-start peak, not steady-state.** Helm chart defaults are sized for steady-state reconcile; cold-start with a nontrivial app-of-apps graph (>3 apps, >1 Helm app with a large chart) routinely peaks 2–3× steady-state. Budget 1 Gi limit + 512 Mi requests as a floor for any cluster that will ever cold-start with > 2 ArgoCD apps.

- **Include ArgoCD controller health in the platform-first-verification runbook's §9 checklist** as an explicit item (not just "ArgoCD 6/6"). Specifically look for non-zero restart counts on `argocd-application-controller-0`; any restart count within the first 10 minutes of cluster life is evidence of this class of bug.

- **Consider deferring non-essential ArgoCD Applications to post-bring-up.** If the root app-of-apps synthetically waits 60s before kicking off child Applications, the controller's cold-start work spreads out across time and peak memory drops. Orthogonal to memory limits; complementary.

### Lessons

- **Cold-start OOM is asymmetric and hard to reproduce.** The same chart, same cluster size, same apps can OOM on one cluster and not another depending on microsecond-level ordering. Post-hoc reproduction is flaky; the right response is to raise the memory limit and move on, not to debug which 100 ms sliver of reconcile pushed the controller over.

- **"Same config, different behavior" across slot-pattern clusters is worth flagging.** A forked design would naturally produce identical behavior; the slot pattern does too *for configuration*, but operational behavior can still diverge due to load ordering. Session C validated that the slot pattern pushes the same code to both clusters (correct); it also surfaced that identical code under identical config can still exhibit different runtime health (expected, but worth documenting in the ADR-018 Consequences as "per-cluster observability is independent — including where cluster-specific failures surface").

- **Load-testing for cold start is not just a capacity-planning exercise.** It is also a reliability exercise: cold start is the moment after any disaster (region failover, primary outage, scheduled teardown/re-apply for cost). Under-sizing for cold start is equivalent to under-sizing for recovery. Worth pulling forward into ADR-015 Consequences as "Observability stack capacity must tolerate cold-start peak, not just steady-state."

---

## Incident 30 — Teardown sweep silently fails to clear EKS cluster SG; `|| true` masks the real AWS error

**Date**: 2026-04-20 (Session C teardown, first attempt; the workloads slot-pattern refactor landed earlier the same day in PR #100)
**Severity**: S2 (blocks VPC destroy; recoverable by manual cleanup + re-trigger)
**Duration**: ~25 minutes between the failed first teardown and the successful retry, of which ~2 min was actual diagnosis and ~22 min was the first teardown's own protracted destroy of `vpc_slave_1` (unrelated but concurrent)

### Symptom

The `Destroy staging/network` job of `terraform-teardown-workload.yml` run [#24655477762](https://github.com/BinHsu/aegis-aws-landing-zone/actions/runs/24655477762) reported `completed / failure` with:

```
Error: deleting EC2 Subnet (subnet-00353c54bf635e587): operation error EC2:
  DeleteSubnet, api error DependencyViolation: The subnet
  'subnet-00353c54bf635e587' has dependencies and cannot be deleted.
```

The `Sweep orphan EKS security groups in target VPC` step of the same job had run **before** `terraform destroy` and reported `success` — including explicit notice messages:

```
notice::Sweeping orphan EKS SGs in VPC vpc-098e0945f1184f89d
notice::Deleting orphan EKS SG sg-050f60eb1eaf4318a
```

Yet post-failure AWS CLI inspection showed that `sg-050f60eb1eaf4318a` was **still present** in the VPC, with one `available`-status ENI (`eni-0fae04c9c315ec417`, description `aws-K8S-i-066c223f64bee5662`) still using it in the `Groups` list.

### Root cause

The sweep step silently fails and claims success. Two collaborating defects:

**1. Sweep deletes SGs before ENIs, but ENIs hold the SGs.**

The step's body only targets EKS-cluster-tagged security groups (`tag-key = aws:eks:cluster-name`). It does not look for orphan ENIs at all. But the EKS cluster SG (`eks-cluster-sg-<cluster>-<suffix>`) cannot be deleted while *any* ENI references it. When the platform layer's prior `terraform destroy` tears down the EKS cluster, AWS releases the control-plane-managed ENIs asynchronously — a process that routinely takes several minutes after the cluster's control plane is gone. If the network-layer sweep runs while at least one of those ENIs is still in the `available` state (detached but not yet deleted), the sweep's `delete-security-group` call hits `DependencyViolation` from AWS.

**2. `|| true` on the delete command eats the error.**

The workflow step includes:

```bash
aws ec2 delete-security-group --region $AWS_REGION --group-id "$SG" || true
```

The `|| true` is intended to not abort the sweep step on a single SG failure. In effect, it also hides any AWS error (`DependencyViolation`, permission denied, rate limit) — the step exits 0, the workflow considers it green, and `terraform destroy` proceeds assuming the sweep was effective. It was not.

The cascade: platform destroy leaves orphan ENI + SG → network sweep finds SG, tries delete, AWS refuses with DependencyViolation, `|| true` masks → step claims success → Terraform tries to delete subnet → ENI in subnet blocks → DependencyViolation on subnet → job fails.

### Detection

After the workflow reported failure, a post-hoc AWS CLI sweep confirmed:

```bash
AWS_PROFILE=aegis-staging-admin aws ec2 describe-vpcs --region eu-central-1 \
  --filters "Name=tag:Project,Values=landing-zone-lab" \
  --query "Vpcs[].VpcId"
# returned vpc-098e0945f1184f89d — still there

AWS_PROFILE=aegis-staging-admin aws ec2 describe-network-interfaces --region eu-central-1 \
  --filters "Name=vpc-id,Values=vpc-098e0945f1184f89d" \
  --query "NetworkInterfaces[].[NetworkInterfaceId,Status,Description,Groups[].GroupName]"
# returned eni-0fae04c9c315ec417  available  aws-K8S-i-066c223f64bee5662  [eks-cluster-sg-...]
```

Cross-checked the sweep step's actual behavior via:

```bash
gh run view 24655477762 --log | grep -E "Sweep|Deleting orphan"
```

Which revealed the "Deleting orphan EKS SG sg-050f60eb1eaf4318a" notice — the sweep *tried* and the step *claimed success* but the resource was still there, proving the masked error.

### Resolution

Manual ENI + SG cleanup, then re-trigger teardown:

```bash
AWS_PROFILE=aegis-staging-admin aws ec2 delete-network-interface \
  --region eu-central-1 --network-interface-id eni-0fae04c9c315ec417

AWS_PROFILE=aegis-staging-admin aws ec2 delete-security-group \
  --region eu-central-1 --group-id sg-050f60eb1eaf4318a

gh workflow run terraform-teardown-workload.yml -f env=staging
# approve when prompted; retry completed all 3 layers green in ~3 min
```

Important: delete ENI first, then SG. Reverse order produces the same `DependencyViolation` the sweep's own command ate.

### Prevention

Fix the sweep in a dedicated PR. Concrete scope:

1. **Delete orphan ENIs before orphan SGs.** In the same step, add an ENI sweep pass:

   ```bash
   ENI_IDS=$(aws ec2 describe-network-interfaces \
     --region $AWS_REGION \
     --filters "Name=vpc-id,Values=$VPC_ID" \
               "Name=status,Values=available" \
     --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)
   for ENI in $ENI_IDS; do
     aws ec2 delete-network-interface --region $AWS_REGION --network-interface-id "$ENI"
   done
   ```

   Then the existing SG pass. Order matters: ENI must go first.

2. **Drop `|| true`; check the API response.** Rewrite the delete call so a genuine failure surfaces:

   ```bash
   if ! aws ec2 delete-security-group --region $AWS_REGION --group-id "$SG" 2>err.log; then
     echo "::error::Failed to delete SG $SG:"
     cat err.log
     exit 1
   fi
   ```

   A per-SG failure now halts the sweep, fails the step loudly, and forces the operator (or a retry strategy) to look at what AWS actually said. This is strictly better than the silent mask, which produced this exact incident.

3. **Consider a post-sweep wait-for-zero-ENI check.** Before `terraform destroy` runs, the step could poll AWS for `NetworkInterfaces` in the VPC and wait (with timeout) for the count to reach zero. If AWS is still releasing control-plane ENIs, the destroy should wait rather than race.

Track as follow-up PR alongside the Incident 26-29 fix PR.

### Lessons

- **`|| true` is a lie detector.** Whenever a shell step ends with `|| true`, it is declaring that "silent failure here is acceptable." Sometimes that's true (best-effort cleanup where a later step will verify). More often it's a defensive habit that masks real problems. In this case, the sweep existed *specifically* to prevent a known cascade — `|| true` on its own delete was the exact wrong place to declare failure acceptable.

- **Post-destroy AWS state is asynchronous.** EKS cluster teardown releases ENIs *asynchronously* — the control plane itself is gone before the ENIs it attached finish being reclaimed. Any "do X before Y" workflow step that implicitly assumes AWS completed all side effects before it runs needs either a wait loop, a retry, or a read-back verification step. Not a fire-and-forget.

- **Step-success is not a real signal for state-modifying actions.** A green step in GitHub Actions means "the shell exited 0," not "AWS did what I asked." For state-changing sweeps, the step should verify post-condition (target resource gone) before exiting 0. This is the workflow-level analog of the "plan ≠ apply" lesson in Incident 25.

- **Log-to-diagnose requires traceable command output.** The sweep's NOTICE message was `Deleting orphan EKS SG sg-050f60eb1eaf4318a` — it did not include AWS's actual error. Adding `set -x` at the top of the step, or printing the AWS CLI response on failure, would have made the incident 10× faster to diagnose. Also worth considering: run the sweep with `--debug` or capture `--cli-read-timeout` + retry behavior to surface propagation delays in logs.

- **Defense in depth is still fallible if the outer defense lies.** The sweep was added in PR #98 as a belt-and-suspenders fix for exactly this class of orphan-SG-blocks-VPC problem. It lived up to its charter in the happy path. It failed in the edge case where the SG is *not-yet-deletable* rather than *not-found*. Belt-and-suspenders works when both layers fail loudly; when one silently hides failure, it gives false assurance that the other isn't needed. Every redundant safety layer needs the same "fail loudly" discipline — quiet fallbacks reintroduce the exact failure mode the layering was supposed to prevent.

---

## Incident 31 — ServiceMonitor CRD bootstrap race + break-glass local apply

**Date**: 2026-04-20 (mid-session, post-merge of PRs #106–111, cold-apply validation run)
**Severity**: S2 (platform apply blocked; recoverable; triggered a break-glass local apply decision that is itself a process-governance issue worth recording)
**Duration**: ~15 min diagnosis + ~10 min code fix + ~8 min local re-apply ≈ 33 min wall

### Symptom

`terraform-apply-workload.yml` run [24677044105](https://github.com/BinHsu/aegis-aws-landing-zone/actions/runs/24677044105) — the first cold apply after Session C's Incidents-26–30 fixes merged — failed in the `Apply staging/platform` job:

```
Error: unable to build kubernetes objects from release manifest:
  resource mapping not found for name: "cert-manager" namespace:
  "cert-manager" from "": no matches for kind "ServiceMonitor" in
  version "monitoring.coreos.com/v1"

Error: context deadline exceeded
```

Network job succeeded; workloads job was `skipped` due to the platform failure. Cluster left in partial state (EKS control plane up, some Helm releases installed, cert-manager half-installed).

### Root cause

**The bug (Symptom-level)**: cert-manager's Helm chart was configured with `prometheus.servicemonitor.enabled = true` in `terraform/environments/staging/platform/modules/eks-cluster/cert-manager-helm.tf`. The chart then templates a `ServiceMonitor` resource. The `ServiceMonitor` CRD belongs to **Prometheus Operator**, which is shipped by `kube-prometheus-stack` in the **workloads** layer — applied *after* platform. Platform's `helm_release` has `wait = true` (default), so Helm failed synchronously on the missing CRD and the platform apply aborted.

**The deeper cause (design-level)**: the ADR-015 §Discovery contract encourages every component to emit metrics via ServiceMonitor for auto-discovery. The pattern was applied to cert-manager + argo-rollouts without tracing the cross-layer CRD dependency. Platform-layer components CANNOT assume Prometheus Operator CRDs exist — the CRDs don't arrive until the workloads layer syncs them.

This is structurally the same class as Incident 26 (Kyverno ClusterPolicy CRD race against ArgoCD-managed chart sync), with a different twist: Incident 26's race was within-cluster (TF vs ArgoCD async). This one is across-layer (platform TF synchronous vs workloads TF synchronous, different order). Same root discipline: **do not reference CRDs whose install layer runs after your layer**.

### Detection

Platform apply job failed cleanly with a clear error chain:
```
gh run view --job 72165523013 --log-failed | grep -E "Error:"
```
returned the `no matches for kind "ServiceMonitor"` line directly. No state-rm forensics needed.

The secondary `context deadline exceeded` was a symptom of Helm retry timing out — not an independent issue.

### Resolution

**Fix (code)**: disable chart-template-level `ServiceMonitor` creation in both cert-manager (platform) and argo-rollouts (workloads, same race with kube-prometheus-stack via ArgoCD sync ordering):

```hcl
# cert-manager-helm.tf
prometheus = {
  enabled = true
  servicemonitor = { enabled = false }
}

# argo-rollouts.tf
metrics = {
  enabled = true
  serviceMonitor = { enabled = false }
}
```

Metrics endpoints stay enabled (`/metrics` on the Service). Explicit `ServiceMonitor` resources added in the workloads layer (where kube-prometheus-stack CRDs are already present) is the follow-up.

**Fix (apply path) — **break-glass**: NAT gateway was running ($0.045/hr) and re-triggering the CI workflow would have added ~30–45 min before re-apply could start. The operator (Bin) chose to apply platform locally using AWS SSO credentials:

```bash
cd terraform/environments/staging/platform
AWS_PROFILE=aegis-staging-admin terraform init -input=false
AWS_PROFILE=aegis-staging-admin terraform apply -auto-approve -input=false
```

A PR containing the same code delta ([#119](https://github.com/BinHsu/aegis-aws-landing-zone/pull/119)) was opened *concurrently with* the local apply, so main branch catches up within the same session via the normal merge path.

### Prevention

**Technical (CRD dependency audit)**: any Helm release in layer N that templates a CRD belonging to a controller that installs in layer N+1 or later is a latent bug of this class. Concrete audit path before future apply-path changes:

```bash
helm template <chart> <values> | grep -E "^kind: (ServiceMonitor|PodMonitor|PrometheusRule|Certificate|Issuer|Rollout)" 
```

If the release is in a layer where those CRDs are NOT yet installed, either (a) turn off the chart flag that creates them, or (b) move the release to a layer that runs after the CRD provider, or (c) add an explicit standalone resource in a later layer.

**Process (break-glass discipline)**: this incident triggered a local apply — the first time in this project. The choice itself was defensible (cost + time justified the break-glass pattern), but the project had no documented rule for when break-glass is acceptable and what compensating controls are required. That gap is now closed: [`docs/principles/break-glass-apply.md`](principles/break-glass-apply.md) documents the default-forbidden position, the specific allowed scenarios (CI outage, mid-session cost, security response), the forbidden scenarios ("I want it fast"), and the compensating-control obligations (concurrent PR + main catches up + incident entry referencing the doc).

**Observability follow-up**: once the cluster is up and kube-prometheus-stack is installed, add explicit `ServiceMonitor` resources in `staging/workloads/modules/eks-workloads/` that target cert-manager + argo-rollouts Services. Cross-repo note: aegis-core workloads use the same discovery contract and don't hit this race because their `ServiceMonitor` resources are application-authored, applied after platform+workloads.

### Lessons

- **CRD ownership crosses layer boundaries.** ADR-015's discovery contract says "workload teams can ship ServiceMonitor anywhere and Prometheus Operator picks it up." True. What the contract did *not* explicitly say is that *platform-layer* components cannot ship ServiceMonitors either — their layer runs before the CRD is created. The bootstrap constraint is asymmetric: consumer layers can assume CRDs exist; producer layers (and anything that runs before the producer) cannot.

- **`helm_release wait=true` is load-bearing but also unforgiving.** The flag is the right choice for synchronous CRD handoff (ADR-016 for Kyverno) but turns every missing-CRD edge case into a hard failure. Worth knowing when reading any `helm_release` block: "this is a synchronous fence; a missing dependency stops the layer."

- **The first cold apply after a fix-set PR batch is a high-risk event.** Incidents 26–30 all surfaced on Session C's cold apply; this incident (31) surfaced on the cold apply *after* those fixes merged. Fix batches interact with each other in the first cold-apply on a clean slate — previous session state masks dependency assumptions. Plan for this by not batching more than 3–4 substantive fixes into a single pre-cold-apply merge window, or by doing a cold-apply dry-run on a length-1 config before the length-2 portfolio apply.

- **Break-glass local apply is acceptable but NOT cheap.** The governance cost of this incident is ~1 hour of documentation work (principle doc + this incident + compensating-control PR coordination), comparable to the CI cycle time we saved. Break-glass is strictly worth it only when CI cycle time exceeds the documentation cost AND when the cost multiplier (NAT running, cluster half-applied) exceeds both. Over-using break-glass erodes the repo's "drift is a bug" posture faster than any other pattern — discipline tax is real and must be paid.

- **Concurrent PR is not optional.** The compensating control for break-glass is not "open a PR sometime later" — it is "open a PR concurrent with or before the apply." PR #119 was opened *before* `terraform apply` ran locally. If the PR had been opened *after*, the commit history would have shown "apply happened" → "code landed" rather than "code landed" → "apply happened," and main branch would have represented the wrong state to any observer for the intervening minutes.

---

## Incident 32 — Break-glass cascade: four local applies + stuck destroy after one "simple" recovery

**Date**: 2026-04-20 (continuation of the same session as Incident 31)
**Severity**: S2 (cost: ~$0.29/hr AWS burn for ~45 min; discipline: violated the principle doc written 30 min before its own violation)
**Duration**: ~1.5h elapsed from "first break-glass looked simple" to "stop, teardown via CI-only"

### Symptom

The single-event break-glass apply from Incident 31 — intended as one targeted fix — cascaded into **four** local `terraform apply` runs as one edge case revealed another:

1. **Apply #1** (fix ServiceMonitor) — partially succeeded; `helm_release.cert_manager` and `helm_release.argocd` timed out on post-install wait because Karpenter's NodePool `limits.cpu=4` kept picking tiny instances (t3.micro 1GB RAM) that couldn't fit ArgoCD controller's 1Gi memory request (raised in PR #106)
2. **Apply #2** (after `kubectl delete node` of the t3.micro forced Karpenter to repack to m5.large) — hit the same ServiceMonitor error because the local repo was on the wrong branch (`docs/break-glass-discipline-plus-incident-31` instead of `fix/disable-operator-servicemonitors-platform-bootstrap`)
3. **Apply #3** (on correct branch) — saw `helm_release.kyverno` marked *tainted* from Apply #1 (terraform's treatment of helm_release that timed out during a failed parallel install) and attempted destroy-replace; `helm uninstall` hung for 5 min because Kyverno chart marks CRDs with `helm.sh/resource-policy: keep`, blocking uninstall completion
4. **Apply #4** (after `terraform untaint` on both helm_release.kyverno entries) — succeeded at updating the helm releases but failed trying to create ClusterPolicies because cluster state had drifted

Then the **teardown** workflow, when triggered via CI, failed too — `helm_release.kyverno` hung on destroy (same resource-policy: keep issue) and blocked platform-destroy.

### Root cause

Three interlocking causes, each innocuous alone; catastrophic in combination:

**Cause 1 — NodePool capacity was tight enough that cold-start was a coin flip**. `limits.cpu = 4` plus `instance-cpu = ["2", "4"]` (no memory floor) meant Karpenter's cheapest-spot selector could pick t3.micro (1GB), which can't fit modern controller images at their request size. When all operator Helm charts install concurrently during cold apply, this is not a rare edge — it's the default.

**Cause 2 — Kyverno chart marks CRDs with `helm.sh/resource-policy: keep`**. This is the chart's way of preventing accidental CRD deletion during upgrade (which would cascade-delete all policies). But combined with `helm_release.wait = true`, destroy hangs: helm "deletes" the release but leaves CRDs behind, then waits for "all resources gone" which never becomes true.

**Cause 3 — terraform helm_release taints the resource on timeout without distinguishing "install failed" from "wait failed but install is fine"**. The physical helm release was fine (pods Running), but terraform's state said "failed, must replace." Replacing a fine release means destroy + re-create, which re-triggered Cause 2.

The first break-glass looked isolated (fix ServiceMonitor + re-apply). The second was "just" fixing a branch mistake. The third was "just" `terraform untaint`. Each was one line of justification that disguised the fact we were *accumulating* exceptional actions instead of resolving them.

### Detection

The break-glass *count* only became obvious when Bin asked "we keep doing local terraform apply?" mid-session. Nothing in the workflow alerted on it — the principle doc was written 30 minutes before the cascade but not yet operationalized as an actual check. A human caught it; tooling didn't.

Cost detection: `aws eks list-clusters` + `aws ec2 describe-nat-gateways` after the cascade showed 2 EKS clusters + 2 NAT gateways still running despite multiple teardown attempts. That was the concrete signal that break-glass had become an anti-pattern in this session.

### Resolution

Discipline-correct recovery:

```bash
# 1. Cut losses — do NOT attempt a 5th local apply
# 2. Trigger teardown via CI (terraform-teardown-workload.yml)
gh workflow run terraform-teardown-workload.yml -f env=staging
# 3. When platform destroy hangs on helm_release.kyverno, state-rm it:
cd terraform/environments/staging/platform
AWS_PROFILE=aegis-staging-admin terraform state rm \
  module.cluster_primary.helm_release.kyverno \
  'module.cluster_slave_1[0].helm_release.kyverno'
# 4. Re-trigger teardown workflow
gh workflow run terraform-teardown-workload.yml -f env=staging
# 5. Verify AWS resources are clean:
AWS_PROFILE=aegis-staging-admin aws eks list-clusters --region eu-central-1
AWS_PROFILE=aegis-staging-admin aws ec2 describe-nat-gateways \
  --region eu-central-1 --filter "Name=state,Values=available"
```

State-rm is the correct tool for "terraform thinks it owns a resource it can't actually manage right now." Once state says "not my problem," destroy can proceed past kyverno and take down the EKS cluster, which cascades K8s resources (including orphaned kyverno pods + CRDs) into oblivion.

### Prevention

Structural (land as separate PRs, not all this session):

1. **NodePool capacity floor** (PR #122): raise `limits.cpu` 4 → 8, add `instance-memory > 3800 MiB` to exclude tiny-RAM instances. Makes Cause 1 impossible.
2. **helm_release Kyverno handling**: either (a) set `skip_crds = false` and manage CRDs out-of-band, (b) add `provisioner "local-exec" { when = destroy }` that runs `kubectl delete crd` for Kyverno CRDs before the helm destroy, or (c) use `lifecycle { ignore_changes = [...] }` patterns that work around the resource-policy-keep interaction. All three are open-ended; tracked as an `improvements/` entry.
3. **ArgoCD sync-waves** for Kyverno CRDs vs policies (cross-check against PR #107 Kyverno-as-platform decision).

Process (this is the bigger win):

1. **Operationalize the break-glass count**: if a session has > 1 local apply, STOP. Do not proceed to apply #2 without first writing the Incident-32-equivalent post-hoc — the act of writing forces the question "is this still one event or are we looping?"
2. **CI-only teardown as the escape hatch**: even mid-cascade, teardown via CI + OIDC is the discipline-correct exit. Cost is "today's session is a draft; next session is the real run."
3. **No partial apply demos**: a Grafana screenshot taken on a half-messed cluster is worth less than the discipline cost of getting it.

### Lessons

- **Break-glass is not a mode; it's an event**. The principle doc (`docs/principles/break-glass-apply.md`, committed in PR #121) was written clearly enough that a reviewer reading it in isolation would know the rule. But the *operator* of the project (me) violated it within 30 minutes of writing it by treating "just one more local apply to unstuck this" as outside the principle's scope. It is not outside. Every local apply is a break-glass event, and **N break-glasses in a session is an anti-pattern** regardless of how each one was individually justified. This is the most important lesson of this session: rules have to survive the operator's own "but this one's different" reasoning.

- **terraform's helm_release failure semantics are not fine-grained enough for this class of chart**. `wait = true` bundles "install completed" and "post-install hooks reached Ready" into a single pass/fail signal. For charts with long post-install waits (admission controllers, anything with initContainers that need a specific K8s resource provisioned), this pattern is structurally fragile on cold-start. The fix isn't `wait = false` (which masks real failures) but a separate "health check" resource that Terraform can wait on independently of the chart's installation path.

- **"`kubectl delete node`" on Karpenter is cleaner than touching `terraform`**. The one non-terraform action in the cascade (deleting the t3.micro to force Karpenter repack) was the only action that was both fast and discipline-neutral — it manipulated cluster state without touching terraform state. If Karpenter were an in-cluster concern only and terraform just managed the NodePool spec, many cascade paths would not exist. Worth thinking about at future module boundaries.

- **A principle's first stress test is whether it survives the day it was committed**. This is a reliability property of the principle, not a separate bug. "Break-glass is rare" is operational folklore; "break-glass is *counted, logged, and capped per session*" is engineering. The project needs the latter — PR #121's principle doc is incomplete without at least a (manual or automated) per-session counter.

- **Rolling back gracefully is its own operational muscle.** state-rm + retry-workflow is the kind of thing that reads as "obvious once you know it" and is "terrifyingly opaque under stress." Future runbook should include the state-rm flow for stuck helm_release as a named recipe, not folklore passed between sessions.

---

## Incident 33 — LBC webhook race recurrence: Incident 17 prevention never propagated to 5 later helm_releases; Kyverno finalizer cascade turned a first-apply retry into manual K8s cleanup

**Date**: 2026-04-24 (Phase 4c+ first real end-to-end cold-apply attempting to land Qdrant + aegis-core rollout wiring together)
**Severity**: S2 (blocked full-session cold-apply; blocked teardown retry; forced break-glass kubectl cleanup + ad-hoc SSO EKS Access Entry provisioning to recover)
**Duration**: ~90 minutes from first apply failure to clean teardown completion — 2 failed apply attempts + 2 failed teardown attempts + manual K8s cleanup session

### Symptom

Fresh cold-apply (`gh workflow run terraform-apply-workload.yml -f env=staging`) on an empty state, after the pre-flight prep described in PR #148 (Runbook 007 unfreeze, Qdrant SSM PS imported, etc.). `apply-network` passed in ~3-5min. `apply-platform` failed ~10min later with the signature of Incident 17 but fanned across **five independent helm_releases × two clusters**:

```
Error: Internal error occurred: failed calling webhook "mservice.elbv2.k8s.aws":
failed to call webhook: Post
"https://aws-load-balancer-webhook-service.kube-system.svc:443/mutate-v1-service?timeout=10s":
no endpoints available for service "aws-load-balancer-webhook-service"

(and 7 more similar warnings elsewhere)

Error: 3 errors occurred:
  (cert_manager × 2 clusters)
Error: 1 error occurred:
  (external_secrets × 2 clusters)
Error: 1 error occurred:
  (kube_state_metrics × 2 clusters)
Error: 6 errors occurred:
  (kyverno × 2 clusters)
```

Per-resource summary from the failed plan log: cert-manager, external-secrets, kyverno, kube-state-metrics, on both the `primary` and `slave_1` EKS clusters. Total ~22 individual Service-admission failures (multiple Services per chart × 2 clusters). ArgoCD (which HAD `depends_on = [helm_release.aws_lb_controller]` from Incident 17's original fix) succeeded cleanly; that was the single chart that followed the rule.

Naive retry (`gh workflow run terraform-apply-workload.yml -f env=staging` immediately) made the situation worse: cert-manager + ESO + KSM + node-exporter retried fine (LBC pod Ready by then), but Terraform's second-run plan saw the Kyverno helm_release in `failed` state and attempted to **destroy-then-recreate**. `helm uninstall kyverno` then hung for 5 minutes with `timed out waiting for the condition`, producing a second workflow failure with cluster now in a partially-torn-down state (Kyverno pods re-created by ReplicaSet controller while Helm tried to delete them, Kyverno CRDs with finalizers blocking CR cleanup, admission webhooks still registered).

Teardown workflow (`gh workflow run terraform-teardown-workload.yml -f env=staging`) then failed at `destroy-platform` with a **mirror-image webhook race**: ESO's `helm_release` destroyed before `ClusterSecretStore aegis-ssm` could be deleted, because the ClusterSecretStore delete requires validation via `validate.clustersecretstore.external-secrets.io` — whose backing service (`external-secrets-webhook`) is gone after the helm_release destroy. Same Kyverno timeout surfaced on the destroy path.

Result: 2 EKS control planes + NAT + Karpenter EC2 burning ~\$0.30/hr with no clean path forward via CI.

### Root cause

**Incident 17's prescription was written and never applied to the helm_releases added after 2026-04-14.**

Incident 17 (2026-04-14) identified that LBC's MutatingWebhookConfiguration `mservice.elbv2.k8s.aws` intercepts **every** `Service` creation cluster-wide, not just `type=LoadBalancer`. The fix was a one-line `depends_on = [helm_release.aws_lb_controller]` on `helm_release.argocd`. The Prevention section explicitly generalized the rule: *"If a Helm chart installs a cluster-wide admission webhook, every subsequent Helm chart that creates resources the webhook intercepts must `depends_on` the webhook's chart."* That generalization was accurate and complete — but was expressed only in prose, with no enforcement mechanism and no reminder baked into `lb-controller.tf` itself.

Five subsequent helm_releases were added to `modules/eks-cluster/` (cert-manager, external-secrets, kyverno, kube-state-metrics, plus implicitly downstream charts like alloy) and NONE of them added the prescribed `depends_on`. Terraform's resource graph gave no signal — these resources are not attribute-referenced by `aws_lb_controller`, so Terraform schedules them in parallel. When Karpenter hadn't yet provisioned an EC2 node for the LBC pod (cold-cluster case), the webhook service had zero endpoints at the moment these helm charts created their Services.

The Kyverno-destroy-hang was a second-order effect: Kyverno's first-apply created CRDs with finalizers but hadn't fully installed its own admission controller, leaving the cluster in a state where Kyverno's uninstall requires Kyverno's own webhooks to validate CR deletions — but those webhooks can't fire because the controller never reached Ready. Terraform saw `helm uninstall` timeout and gave up. Retrying without manual cleanup perpetuated the loop.

The teardown-path webhook race (ClusterSecretStore blocking on ESO's own validation webhook after ESO is destroyed) is **structurally identical** to the apply-path race but flows in the opposite direction. Same missing-depends_on class; Incident 17's Prevention rule would have caught both if applied.

### Detection

First-run failure was unambiguous from CI logs — error text explicitly named `aws-load-balancer-webhook-service` across 22 failures. Pattern-matched Incident 17 instantly. The misdiagnosis of naïve retry as "webhook race self-resolves once LBC is Ready" was partially correct (4 of 5 charts recovered) but missed that Kyverno specifically poisons its own retry path.

Teardown failure detected via workflow job log: `aegis-ssm failed to delete kubernetes resource: Internal error occurred: failed calling webhook "validate.clustersecretstore.external-secrets.io"` — same admission-webhook-with-no-endpoints signature, different chart.

Operator lockout detection during manual recovery: `kubectl auth whoami` returned `Unauthorized` despite valid SSO credentials. `aws eks list-access-entries` showed only `github-actions-terraform`, `AWSServiceRoleForAmazonEKS`, and the Fargate pod-execution-role — no entry for the human SSO role `AWSReservedSSO_PlatformAdmin_*`. This gap was independent of Incident 33 (a pre-existing deficiency the incident exposed) but materially blocked recovery.

### Resolution

Full manual cleanup + teardown retry sequence (executed with operator SSO after ad-hoc Access Entry creation):

1. **Grant SSO role temporary EKS access on both clusters** (required because the platform layer's Terraform never provisioned an Access Entry for the SSO admin role — pre-existing gap, flagged as follow-up below):

   ```bash
   SSO_ROLE="arn:aws:iam::251774439261:role/aws-reserved/sso.amazonaws.com/eu-central-1/AWSReservedSSO_PlatformAdmin_5f5772e2bfd724a3"
   for region_cluster in "eu-central-1 aegis-staging-primary" "eu-west-1 aegis-staging-slave-1"; do
     region=$(echo $region_cluster | awk '{print $1}')
     cluster=$(echo $region_cluster | awk '{print $2}')
     aws eks create-access-entry --cluster-name $cluster --region $region \
       --principal-arn "$SSO_ROLE" --type STANDARD
     aws eks associate-access-policy --cluster-name $cluster --region $region \
       --principal-arn "$SSO_ROLE" \
       --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
       --access-scope type=cluster
   done
   ```

2. **Delete ESO ValidatingWebhookConfiguration** (the one blocking ClusterSecretStore deletion) on both clusters:

   ```bash
   kubectl --context $ctx delete validatingwebhookconfiguration secretstore-validate
   ```

3. **Patch + delete `ClusterSecretStore/aegis-ssm`** (finalizer was empty but the webhook rejection was the block — step 2 was required first):

   ```bash
   kubectl --context $ctx patch clustersecretstore aegis-ssm -p '{"metadata":{"finalizers":null}}' --type=merge
   kubectl --context $ctx delete clustersecretstore aegis-ssm
   ```

4. **Delete Kyverno admission webhook configs** (remove the stuck validation that would block CRD deletes):

   ```bash
   kubectl --context $ctx get mutatingwebhookconfiguration,validatingwebhookconfiguration -o name \
     | grep -i kyverno | xargs -r kubectl --context $ctx delete
   ```

5. **Patch finalizers off + delete all 12 Kyverno CRDs** (cascades to any remaining CRs; CRDs themselves had finalizers):

   ```bash
   for crd in $(kubectl --context $ctx get crd -o name | grep kyverno); do
     kubectl --context $ctx patch $crd -p '{"metadata":{"finalizers":null}}' --type=merge
   done
   kubectl --context $ctx get crd -o name | grep kyverno \
     | xargs -r kubectl --context $ctx delete --timeout=30s
   ```

6. **Re-trigger teardown workflow** — completed cleanly on this retry because the cluster-side blockers were gone.

7. **Fix PR** follows: 4 files × `depends_on = [helm_release.aws_lb_controller]` + a prominent policy comment at the top of `lb-controller.tf` enumerating compliance and the rule for future authors.

### Prevention

1. **Structural fix** (this incident's fix PR): explicit `depends_on = [helm_release.aws_lb_controller]` added to `cert-manager-helm.tf`, `external-secrets-helm.tf`, `kyverno-helm.tf`, `kube-state-metrics.tf`. These are the 4 charts that demonstrably failed; `alloy.tf` transitively waits via `external_secrets` and is not load-bearing today (flag for follow-up audit).

2. **Documentation fix**: prominent policy comment at the top of `lb-controller.tf` (not buried in a separate doc) enumerates the rule and current compliance status. Future helm_release additions reviewing the file at PR time will see the rule inline. This is the weakest part of the fix — relies on author compliance — but is the cheapest to ship. Long-term a pre-commit / Checkov custom rule checking `helm_release` → `depends_on` → `helm_release.aws_lb_controller` for charts that create Services would be stronger; out of scope for this PR.

3. **Kyverno-specific hardening**: consider `atomic = true` on `helm_release.kyverno` so a failed first-apply auto-cleans (rolls back) rather than leaving broken state that poisons retry. Not in this PR (one change per PR principle); flagged for the next Kyverno-touching PR.

4. **EKS Access Entry for SSO admin role**: separate from Incident 33's root cause, but exposed by the recovery path. Platform layer should provision an Access Entry for the SSO admin role (likely derived from `data.aws_iam_policy.sso_administrators` or passed as a config value). Until then, operators needing kubectl access during teardown-recovery will need to create Access Entries ad-hoc via AWS CLI. Follow-up issue to track.

### Lessons

- **"Incidents' Prevention sections must live where the code lives, not in a separate doc."** Incident 17's Prevention rule was correct and comprehensive, but it sat in `docs/incidents.md` and nobody reading the next helm_release PR had it in their working memory. The fix here bakes the rule into `lb-controller.tf` as a prominent top-of-file comment with compliance checklist — future PRs touching that module will see it. Generalizable: every "class-of-bug" prevention rule should have a co-located comment at the natural load-bearing location, not only in the incident log.

- **"Prevention that relies on author compliance without enforcement is technical debt."** The depends_on rule is a code-review convention, not a check. Checkov doesn't catch it; terraform validate doesn't; tflint doesn't. Each new helm_release that misses it is an incident-in-waiting. A custom policy (Checkov/OPA/CEL on the plan) would be stronger. Not a 5-minute fix, but worth scheduling.

- **"Second-order effects from admission webhooks are an order of magnitude worse than the first-order failure."** LBC webhook race on apply is annoying but cleanly recoverable (add depends_on, retry). LBC webhook race **combined with** Kyverno's self-finalizer trap on retry was un-recoverable via CI alone — required 90 minutes of manual kubectl work. The compound failure mode wasn't obvious from Incident 17's write-up. Moral: admission webhooks + finalizers + failed helm_release retry is a three-way deadlock surface that deserves dedicated guard rails (atomic=true, separate namespace lifecycle for CRDs, pre-Ready health checks, etc.).

- **"Break-glass discipline must acknowledge that teardown recovery is structurally different from apply break-glass."** The break-glass-apply principle doc (PR #121) correctly flags unauthorized forward-progress mutations. But teardown recovery — where the goal is to return to clean state — often requires K8s-side intervention (finalizer patching, webhook deletion) that's operationally necessary and not the class of concern the principle addresses. The principle doc should carve out "teardown recovery" as an explicit exception category, or a sibling document should codify the teardown-recovery ritual as a named runbook. Right now the ritual exists only as tribal knowledge that each incident must rediscover.

- **"EKS Access Entry provisioning for human SSO roles is a hidden single-point-of-failure for teardown recovery."** The platform layer cleanly provisions Access Entries for the CI role and the Fargate pod-execution-role, but not for the human SSO admin role. This worked "by accident" in normal flow because the operator never needs kubectl in green-path cold-apply + teardown. The moment the green path deviates and operator intervention is required, the operator is locked out. Fix: provision the SSO Access Entry in the platform layer; until then, document the ad-hoc creation as a known teardown-recovery step.

- **"4 + 1 failures is a pattern, not bad luck."** Incident 17 + Incident 33 + (future): if this same class of bug surfaces a third time, the fix is not another depends_on — it's a structural change to how `helm_release`s declare their admission-webhook dependencies (e.g., a module-level map of "admission-owning helm_releases" that `null_resource`s encode as cluster-wide serialization gates). Flag the structural refactor as a pre-emptive ADR draft if the issue recurs.

---

## Incident 34 — `lifecycle.ignore_changes` does not protect against destroy (2026-04-25)

**Date**: 2026-04-25 (Phase 4c+ post-Incident-33 teardown forensics)
**Severity**: S3 (no production impact; cost is one Qdrant API key re-issuance + ~15 minutes of operator time per recurrence; surfaced as part of Incident 33 recovery, written separately because the lemma generalizes beyond Qdrant)
**Duration**: ~10 minutes from "why is `aws ssm get-parameter` returning NoSuchKey" to root cause

### Symptom

After Incident 33's third teardown attempt finally succeeded, the operator began pre-flight prep for the next cold-apply (Runbook 007 §Part 3 Path A). The first step is verifying SSM PS state:

```bash
$ aws ssm get-parameter --name /aegis/staging/qdrant-cloud/cluster-url --region eu-central-1
An error occurred (ParameterNotFound) when calling the GetParameter operation

$ aws ssm get-parameter --name /aegis/staging/qdrant-cloud/api-key --region eu-central-1
An error occurred (ParameterNotFound) when calling the GetParameter operation
```

Both Qdrant SSM PS resources were gone from AWS, despite the originating Terraform resource declarations carrying `lifecycle { ignore_changes = [value] }`. Operator's prior mental model: "`ignore_changes` protects the resource from drift; teardown is not drift; therefore teardown was protected." That model was wrong.

### Root cause

`lifecycle.ignore_changes` is documented in the Terraform CLI reference as: *"Causes Terraform to skip detecting certain changes in the configuration when planning. Specifically, when these attributes change in the configuration, Terraform will not see them as drift compared to the real-world state, and will leave them as they are during apply."* It is a **drift-suppression** mechanism that operates on the **update** path, not on the **destroy** path.

When `terraform-teardown-workload.yml` ran `terraform destroy` against `staging/observability/`, the tear-down logic walked the resource graph and called the AWS provider's `Delete` for every managed resource, including the two `aws_ssm_parameter` resources owning the Qdrant credentials. `ignore_changes` was never consulted — there was no drift detection phase, only a destroy plan. The SSM PS objects in AWS were deleted accordingly.

The same destroy pathway also removed `aws_ssm_parameter.team_webhooks_slack_aegis` (which carried `ignore_changes = [value]` for the same reason). It held only a placeholder value, so no real loss; but the failure mode is identical and would have destroyed a real Slack webhook URL had one been put-parameter'd.

The semantic gap is subtle but well-documented: `ignore_changes` and `prevent_destroy` are independent levers. The latter blocks destroy entirely (and forces operator override via `terraform destroy -target=...` or temporary spec edit); the former blocks update-time drift only. The pre-Incident-33 codebase had `ignore_changes` everywhere it needed `prevent_destroy`, because the operator's mental model conflated them.

### Detection

Verification step in Runbook 007 §Part 3 Path A (`aws ssm get-parameter` immediately after teardown). The pre-flight is meant to be a no-op confirmation — instead it surfaced the gap in ~5 seconds.

The lemma had been latent since PR #146 merged on 2026-04-24 (one day before Incident 33). Any teardown of `staging/observability/` between PR #146 and ADR-028 would have surfaced it; Incident 33 happened to be the first.

### Resolution

Per-instance recovery (one-shot, can repeat per future occurrence until ADR-028 lands):

```bash
# 1. Qdrant Cloud Portal → Cluster Detail → API Keys → + Create new key
#    Name: engine-<YYYYMMDD>, 90-day, manage/write. COPY (shown only once).
# 2. Re-put both SSM parameters (note: --overwrite NOT needed because resources are GONE from AWS)
AWS_PROFILE=aegis-staging-admin aws ssm put-parameter \
  --region eu-central-1 \
  --name /aegis/staging/qdrant-cloud/cluster-url \
  --type SecureString --key-id alias/aegis-staging-secrets \
  --value '<cluster URL from portal>'

AWS_PROFILE=aegis-staging-admin aws ssm put-parameter \
  --region eu-central-1 \
  --name /aegis/staging/qdrant-cloud/api-key \
  --type SecureString --key-id alias/aegis-staging-secrets \
  --value '<new key>'
# 3. Delete old key in Qdrant portal.
```

Structural fix: [ADR-028](decisions/028-persistent-saas-credential-isolation.md) relocates Path-B SSM PS shells (operator-put values from SaaS portals that don't retain values after first display) to a new baseline-tier `staging/secrets-persistent/` Terraservice layer. The new layer is excluded from `terraform-apply-workload.yml` AND `terraform-teardown-workload.yml` matrices — workload teardowns can no longer reach these resources. Scope: 4 SSM PS (Qdrant cluster-url + api-key, Grafana Cloud bootstrap-token, Slack webhook URL).

### Prevention

Three layers of defense, in order of effectiveness:

1. **Layer-level isolation (the only true guard)**: Path-B SSM PS belong in a Terraservice layer that no automated workflow destroys. ADR-028 §Decision codifies this. Future Path-B resources go in `staging/secrets-persistent/` by default; the layer name self-documents the immunity property.

2. **Read the Terraform CLI reference for both `ignore_changes` AND `prevent_destroy` whenever the topic involves destroy semantics.** They look like sibling protections; they are orthogonal levers operating on different lifecycle phases. The prevention rule is "always consult both docs when designing teardown-aware resources" — not "use one or the other," but "know which lever covers which path."

3. **Mental model correction**: when proposing `lifecycle.ignore_changes`, ask the question *"what happens if this resource's Terraservice layer is destroyed?"* If the answer is "we lose the operator-supplied value with no recovery short of re-issuing from a SaaS portal," then `ignore_changes` alone is insufficient — the resource also needs either layer-level isolation (preferred) or `prevent_destroy = true` (acceptable but UX-poor for any layer with a real teardown workflow).

### Lessons

- **`ignore_changes` and `prevent_destroy` are not aliases**. The operator's prior mental model treated them interchangeably — "this lifecycle block protects the value." That gloss is half-true on the update path and false on the destroy path. Naming them adjacently in HCL syntax (both inside `lifecycle { }`) is a footgun.

- **Layer placement IS the lifecycle**. A resource's true protection level is determined by which Terraservice layer it lives in and which workflows touch that layer. Resource-attribute-level lifecycle blocks are tactics; layer placement is strategy. Future ADRs proposing new resources should answer "which workflow can destroy this and is that the desired blast radius" before any HCL is written.

- **Lemmas deserve their own incident entries even when they emerge mid-cascade**. Incident 33's narrative is the headline failure (LBC race + Kyverno cascade). Incident 34's narrative is the smaller technical fact that misled the operator about Qdrant SSM PS protection. Splitting them into two entries keeps each post-mortem scannable and lets the lemma transfer cleanly to future SaaS-credential resources without dragging Incident 33's full context along.

- **Latent gaps surface when the workflow that exercises them runs for the first time**. PR #146 added the Qdrant SSM PS resources; the first teardown after PR #146 (Incident 33's recovery) was the first time the destroy pathway crossed those resources. The 1-day window between PR #146 merge and Incident 33 is not a coincidence — it's the typical exposure delay for any new resource added to a path that runs on infrequent triggers. Future PRs adding teardown-bound resources should explicitly note "destroy-path tested?" in the change-review-discipline checklist.

- **`prevent_destroy` is not a substitute for layer placement, even when it would technically work**. Setting `prevent_destroy = true` on the Qdrant SSM PS resources before ADR-028 would have caused `terraform-teardown-workload.yml` to hard-fail mid-matrix, requiring operator workaround via `terraform destroy -target=...` to skip the protected resources. That workaround erodes the discipline of "the workflow IS the source of truth for teardown order" — it makes the protection adversarial to the workflow it should coexist with. Layer placement keeps the workflow whole.

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
