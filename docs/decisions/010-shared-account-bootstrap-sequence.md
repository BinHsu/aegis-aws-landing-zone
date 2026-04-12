# 010. Shared Account Bootstrap Sequence

## Status
Accepted

## Context
The Terraform state bucket lives in `aegis-shared` per ADR-003. Account Factory for Terraform (AFT) is the automation mechanism for provisioning new accounts per ADR-008. AFT itself is deployed via Terraform and therefore requires a state bucket. This creates a circular dependency:

```
AFT needs state bucket → state bucket lives in aegis-shared → aegis-shared must be created by AFT → AFT needs state bucket → ❌
```

Every multi-account landing zone that stores Terraform state in a non-management account faces this bootstrap cycle. The question is where to break it and how to document the break so that future operators do not attempt to automate the one step that must be manual.

## Decision

Break the cycle by creating `aegis-shared` manually via Control Tower Account Factory in the AWS console. This is the only account created manually; all subsequent accounts (`aegis-staging`, `aegis-prod`, and any future accounts) are provisioned via AFT after the state bucket exists.

The bootstrap sequence is:

1. **Manual**: Create `aegis-shared` via Control Tower Account Factory console. The account is placed in the Infrastructure OU, given the root email `aws-aegis-shared@binhsu.org`, and assigned the SSO `PlatformAdmin` permission set. This step is documented in Runbook 001 Part 8.
2. **Terraform (local state)**: Deploy `terraform/environments/shared/bootstrap/` with `backend "local"`. This creates the S3 state bucket, enables versioning, and configures the bucket policy for cross-account state access.
3. **Terraform (state migration)**: Run `terraform init -migrate-state` to move the local state into the new S3 bucket. From this point forward, all Terraform operations use S3 with native locking.
4. **Terraform (AFT deployment)**: Deploy AFT into `aegis-shared` with state in the now-operational S3 bucket.
5. **AFT (automated)**: Use AFT to provision `aegis-staging` and `aegis-prod`. These accounts are fully automated — no console clicks.

The manual step (step 1) is a one-time operation that occurs exactly once in the lifetime of the landing zone. It is the only point in the entire project where an account is created via console rather than code.

## Alternatives Considered

**Create aegis-shared via Terraform `aws_organizations_account` resource with local state, skip Account Factory entirely.** Rejected. Control Tower Account Factory applies the full set of baseline guardrails, Config recorder, CloudTrail integration, and SCP inheritance during account creation. Creating the account via raw Organizations API bypasses all of this, requiring manual guardrail enrollment after the fact — which is error-prone and poorly documented. The five minutes saved by skipping the console are lost many times over reconciling Control Tower's expected state with the actual state.

**Store state in the management account to avoid the cycle entirely.** Rejected. This violates the management account boundary in ADR-001 and is a well-documented antipattern. The management account's blast radius must remain minimal, and hosting state there creates an operational dependency that should not exist.

**Use a temporary S3 bucket in the management account, then migrate state to aegis-shared later.** Rejected. This adds a second state migration (management → shared) on top of the local → S3 migration that already exists. Two migrations double the risk of state corruption and double the operational documentation. One clean break is better than two.

**Create all accounts manually via console.** Rejected. This eliminates AFT entirely, removing the automation demonstration that is a core portfolio goal. The entire point of breaking the cycle at aegis-shared is to preserve AFT for everything after the break.

**Use Terraform Cloud or Spacelift as the initial state backend to avoid the S3 chicken-and-egg.** Rejected. Introduces a third-party dependency that the project explicitly avoids (ADR-008 rationale: only AWS first-party services and open tooling). Also does not eliminate the account creation cycle — the shared account still needs to exist before AFT can run.

## Consequences

One account is created manually. This is documented in Runbook 001 Part 8 with explicit step-by-step instructions and is called out as the deliberate exception to the "everything via code" principle. The interview narrative is: "I broke the bootstrap cycle at the minimum viable point — one manual account creation — then automated everything after it."

The shared account's initial creation is not tracked in Terraform state. Its existence is a prerequisite for Terraform, not a product of it. This is the same relationship the management account has with the rest of the infrastructure: it exists before code runs. Documenting this explicitly prevents future operators from trying to `terraform import` the shared account into a state file that lives inside it.

AFT retains full coverage for all non-bootstrap accounts. The `aegis-staging` and `aegis-prod` accounts, plus any future accounts (sandbox, additional workload accounts), are provisioned entirely through code. The portfolio demonstrates both the manual break-glass path and the automated steady-state path.
