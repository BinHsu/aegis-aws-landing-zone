# 014. CI OIDC Role Scope-Down

## Status

Accepted (2026-05-03)

## Context

The CI Terraform roles in `aegis-management` (186052668286), `aegis-shared` (345895787808), and `aegis-staging` (251774439261) authenticate GitHub Actions via OIDC. The question this ADR answers is what those roles are *permitted to do* once an OIDC token is issued — and how that permission set is shaped so a leaked token cannot be turned into an organization compromise.

The trigger is a threat-model audit that mapped four security layers against the realistic fork-PR-OIDC attack vector — an attacker forks the public repo, modifies a workflow file in the PR head, and the merge-commit's modified workflow runs with `id-token: write` granted. CLAUDE.md's *"What is NOT a secret"* clause is explicit that AWS account IDs and IAM role ARNs are committable metadata; the security boundary is therefore at STS, not at obscurity. Account IDs appear in `.github/workflows/*.yml` matrix entries, `terraform/environments/*/backend.tf`, and `docs/incidents.md` — the attacker walks in with the role ARN already known.

Of the four layers, only two are real walls against this specific vector:

| Layer | Mechanism | Effective against fork-PR-OIDC? |
|---|---|---|
| 0 | GitHub repo + environment settings (approval gate, branch protection, env reviewers) | Yes — gates token issuance before the workflow file is read |
| 1 | Workflow `if:` guards | No — fork can strip them from its merge-commit version of the file |
| 2 | IAM trust policy `job_workflow_ref` pinning | No — claim resolves to BASE repo path even on fork-modified workflow |
| 3 | IAM permission scope-down | Yes — evaluated at API call time, independent of how the token was obtained |

Layer 0 is hardened at the GitHub repository level: fork PRs from outside collaborators require approval, `main` carries non-bypassable branch protection, the default `GITHUB_TOKEN` permission is read, and the deployment branch policy is main-only. Layer 0 stops fork PRs from minting OIDC tokens at all.

This ADR addresses Layer 3 — the inner wall that bounds blast radius if Layer 0 is ever bypassed (compromised maintainer credentials, settings drift, a GitHub-side bug, etc.). Layer 1 and Layer 2 are explicitly out of scope as primary defenses; they are documented as defense-in-depth where they happen to provide marginal value.

The CI workflow split is the natural axis for IAM identity differentiation. `terraform-plan.yml` runs on `pull_request`; `terraform-apply-baseline.yml` runs on `push: main`. The OIDC `sub` claim already differentiates these two triggers — `pull_request` versus `ref:refs/heads/main`. This ADR keys role identity off that claim.

## Decision

Each account carries a **2-role split**, keyed off the OIDC `sub` claim that differentiates the two CI triggers.

### 2-role split (per account)

| Role | Trust `sub` claim | Permission character | Risk if token leaked |
|---|---|---|---|
| `gh-tf-plan` | `pull_request` | Read-only — broad `Describe* / List* / Get*`, plus state-object read, state-lock writes scoped to the `*.tflock` suffix, and KMS via S3-conditioned `Decrypt` / `GenerateDataKey` | Recon only — AWS metadata disclosure, which CLAUDE.md classifies as not-secret |
| `gh-tf-apply-baseline` | `ref:refs/heads/main` | Org / IAM / SSO / SCP / IPAM / state-bucket — service-namespace scoped to `aegis-*` resource ARN patterns | Org-level mutation; gated by branch protection and required reviews on `main` |

The unlocking move is `gh-tf-plan` as **read-only**. A fork-PR attacker who hijacks `pull_request` workflow execution and successfully exfiltrates an OIDC token can at most run `terraform plan` — which produces metadata disclosure but cannot change anything. This eliminates fork-PR-OIDC as a meaningful blast-radius source even before Layer 0 is considered.

`gh-tf-apply-baseline` is the only role that can mutate AWS resources, and it is reachable only via the `ref:refs/heads/main` claim — which is to say, only by a workflow run triggered by a merge to `main`. Branch protection on `main` and required reviews gate every such merge.

### Per-account scope

Both roles land in `aegis-management`, `aegis-shared`, and `aegis-staging`. `terraform-plan.yml` runs a matrix across all three accounts on every PR; `terraform-apply-baseline.yml` mirrors that matrix on merge to `main`. The plan-tier API surface differs across accounts (management has Organizations / SSO / SCP reads, shared has IPAM, staging has the per-account bootstrap surface), but the role *shape* — purpose-scoped, sub-claim pinned, inline policy — is identical across instances of the same role.

Total: 6 CI role-policy pairs at steady state — `gh-tf-plan` ×3 and `gh-tf-apply-baseline` ×3.

In addition, the break-glass role `aegis-emergency-break-glass` exists per account as the reserved namespace for incident-only access (see `docs/principles/break-glass-apply.md`). It is not part of the CI surface; it is documented here only so the role inventory is complete.

## Alternatives Considered

### A. Keep `AdministratorAccess` and rely on Layer 0 alone

Rejected. Layer 0 is solid but represents a single class of failure surface. Compromised maintainer credentials, a GitHub-side approval-gate bug, or a settings drift episode would all turn an Admin token into a full-account compromise. A public repo that claims security discipline cannot rest its entire wall on a single layer of GitHub repo settings, however well configured.

### B. A single role per account handling both triggers

Rejected. This would leave one role per account handling both `pull_request` reads and `ref:refs/heads/main` writes. The fork-PR-OIDC bound from "Admin" to "what this account's role can do" is real but does not reach the bound from "writes" to "reads only." The unlocking move is sub-claim-keyed, not account-keyed — a read-only `gh-tf-plan` is what closes fork-PR-OIDC as a blast-radius class.

### C. Defer until production deployment ("not a real lab problem")

Rejected. This is a public repository; the audit trail is itself part of the artifact. A reviewer reading `oidc-github.tf` would correctly conclude that the threat model section of CLAUDE.md is aspirational rather than implemented if the CI roles carried `AdministratorAccess`. The work is bounded and shipping the discipline matters more than waiting for a production trigger.

## Consequences

### Makes easier

- Fork-PR-OIDC stolen-token impact is bounded to AWS metadata disclosure. The largest credential-related class of public-repo risk is closed.
- Each CloudTrail `AssumeRoleWithWebIdentity` event identifies the *purpose* of the assumption — the plan role versus the apply role — not just "Terraform CI." Audit trail goes from "one role did X" to "the plan role did X" / "the apply role did X," which is meaningfully more useful for forensic work.
- A new layer touching a new AWS service produces a clear signal at the policy boundary: `gh-tf-apply-baseline` rejects the action with `AccessDenied` until its policy is extended. This becomes a checklist item in `docs/principles/change-review-discipline.md`.

### Makes harder

- 6 role-policy pairs to keep aligned. Drift between accounts is now possible. Mitigation: a shared module pattern in `terraform/modules/github-oidc-roles/` is a candidate future refactor but explicitly out of scope here — the per-account `oidc-github.tf` files diverge enough on plan-tier API surface that abstracting prematurely would obscure rather than clarify.
- Adding a new AWS service in a future layer produces `AccessDenied` at first apply if `gh-tf-apply-baseline`'s policy has not been extended. Failure is loud (CI fails, no silent corruption), but it is a known operational tax.

### Risks

- `terraform plan -refresh=true` (Terraform's default) may write to the state object during refresh. This would break the `gh-tf-plan` read-only design. The `gh-tf-plan` policy therefore permits `s3:PutObject` on the state-key suffix as a worst-case guard; empirical observation under the S3 native-locking backend can later tighten this if `plan -refresh` proves not to write state.
- Trust policy refinements that would help against "main got compromised + new workflow file added" (Layer 2 `job_workflow_ref` pinning) are not part of this ADR. They are decorative against fork-PR specifically but do help against a post-merge attacker on `main`.

## Related

- [ADR-013](013-landing-zone-repo-topology.md) — the single-repo topology whose CI-level isolation this ADR's role split implements.
- [ADR-002](002-region-and-availability-zone-strategy.md) — sibling guardrail at the SCP layer; orthogonal to this ADR's identity layer but composes — even a compromised apply-tier token cannot operate outside `eu-central-1` / `eu-west-1`.
- [ADR-015](015-permission-boundary-hardening.md) — the SCP-layer inner wall that bounds `gh-tf-apply-baseline` if it is ever compromised.
- [ADR-016](016-detective-controls.md) — the detective control that alerts on a failed OIDC assumption against these roles.
- CLAUDE.md *"What is NOT a secret"* clause — the threat-model premise that account IDs and role ARNs are public-by-design and the wall must therefore live at STS / IAM, not at obscurity.

## Appendix

### A.1 `gh-tf-plan` policy sketch (read-only)

Region tokens are `${primary_region}` placeholders consistent with the CLAUDE.md zero-tolerance rule; the actual `.tf` interpolates from `local.primary_region` / `local.dr_region`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadStateObject",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:GetObjectVersion"],
      "Resource": "arn:aws:s3:::aegis-terraform-state-345895787808/*"
    },
    {
      "Sid": "ListStateBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::aegis-terraform-state-345895787808"
    },
    {
      "Sid": "WriteStateLockOnly",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::aegis-terraform-state-345895787808/*.tflock"
    },
    {
      "Sid": "WriteStateOnRefreshGuard",
      "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": "arn:aws:s3:::aegis-terraform-state-345895787808/*"
    },
    {
      "Sid": "StateKmsForLockfile",
      "Effect": "Allow",
      "Action": ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"],
      "Resource": "arn:aws:kms:${primary_region}:345895787808:key/*",
      "Condition": {
        "StringEquals": {"kms:ViaService": "s3.${primary_region}.amazonaws.com"}
      }
    },
    {
      "Sid": "ReadOnlyEverythingElse",
      "Effect": "Allow",
      "Action": [
        "iam:Get*", "iam:List*",
        "ec2:Describe*",
        "s3:GetBucket*", "s3:ListAllMyBuckets",
        "kms:Describe*", "kms:List*", "kms:GetKeyRotationStatus", "kms:GetKeyPolicy",
        "organizations:Describe*", "organizations:List*",
        "sso-admin:Describe*", "sso-admin:List*", "sso-admin:Get*",
        "identitystore:Describe*",
        "ram:Get*", "ram:List*",
        "ec2:DescribeIpam*", "ec2:GetIpam*",
        "events:Describe*", "events:List*",
        "sns:Get*", "sns:List*",
        "tag:Get*"
      ],
      "Resource": "*"
    }
  ]
}
```

`Resource: "*"` on the last statement is acceptable because every action is read-only. The threat model classifies the metadata revealed as not-secret. The deny floor for the role is "no mutation outside the state-lock suffix and the worst-case state-write guard."

### A.2 `gh-tf-apply-baseline` policy outline

Full JSON lives in each account's `oidc-github.tf`. The structural rules:

- **Resource ARNs**: explicit `aegis-*` prefix or account-scoped `arn:aws:<svc>::<account>:`. No `Resource: "*"` for Create / Update / Delete actions.
- **Region tokens**: always `${primary_region}` / `${dr_region}` interpolation, never literal `eu-central-1` (CLAUDE.md zero-tolerance rule).
- **Tag conditions**: `aws:ResourceTag/Project = landing-zone-lab` on Create / Update / Delete where the service supports condition keys.
- **Service surfaces** are derived from the account-fabric layers each account's `terraform-apply-baseline.yml` matrix entry applies — `management/{bootstrap,scps}`, `shared/{bootstrap,ipam,aft}`, `staging/bootstrap`, `prod/bootstrap`.
- **One inline policy per role per account**, colocated with its `aws_iam_role` resource to avoid cross-file lookup during review.
