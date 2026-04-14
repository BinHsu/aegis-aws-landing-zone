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
