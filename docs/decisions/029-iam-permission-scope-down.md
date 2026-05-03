# 029. IAM Permission Scope-Down for `github-actions-terraform`

## Status

Accepted (2026-05-03).

## Context

The three `github-actions-terraform` IAM roles in `aegis-management` (186052668286), `aegis-shared` (345895787808), and `aegis-staging` (251774439261) carry `arn:aws:iam::aws:policy/AdministratorAccess`. The original `oidc-github.tf` comment labels this *"AdministratorAccess for lab simplicity. Production should scope down."* That deferred work is what this ADR closes.

The trigger is a threat-model audit on 2026-05-03 that mapped four security layers against the realistic fork-PR-OIDC attack vector — an attacker forks the public repo, modifies a workflow file in the PR head, and the merge-commit's modified workflow runs with `id-token: write` granted. CLAUDE.md's *"What is NOT a secret"* clause is explicit that AWS account IDs and IAM role ARNs are committable metadata; the security boundary is therefore at STS, not at obscurity. Account IDs appear in `.github/workflows/*.yml` matrix entries, `terraform/environments/*/backend.tf`, and `docs/incidents.md` — the attacker walks in with the role ARN already known.

Of the four layers, only two are real walls against this specific vector:

| Layer | Mechanism | Effective against fork-PR-OIDC? |
|---|---|---|
| 0 | GitHub repo + environment settings (approval gate, branch protection, env reviewers) | Yes — gates token issuance before the workflow file is read |
| 1 | Workflow `if:` guards | No — fork can strip them from its merge-commit version of the file |
| 2 | IAM trust policy `job_workflow_ref` pinning | No — claim resolves to BASE repo path even on fork-modified workflow |
| 3 | IAM permission scope-down | Yes — evaluated at API call time, independent of how the token was obtained |

Layer 0 was hardened cross-repo on the same day this ADR was written. [aegis-core#112](https://github.com/BinHsu/aegis-core/issues/112) closed with itemized API-cited confirmation; [ldz#170](https://github.com/BinHsu/aegis-aws-landing-zone/issues/170) closed in lockstep. Both repos now require approval for fork PRs from outside collaborators, branch protection on `main` with non-bypassable enforcement, default `GITHUB_TOKEN` permissions set to read, and main-only deployment branch policies on the two ldz Environments. Layer 0 stops fork PRs from minting OIDC tokens at all.

This ADR addresses Layer 3 — the inner wall that bounds blast radius if Layer 0 is ever bypassed (compromised maintainer credentials, settings drift, GitHub-side bug, etc.). Layer 1 and Layer 2 are explicitly out of scope as primary defenses; they are documented as defense-in-depth where they happen to provide marginal value (see Open Question 4).

[ADR-009](009-lifecycle-and-teardown-strategy.md) established the workflow-split discipline: `terraform-plan.yml` runs on `pull_request`, `terraform-apply-baseline.yml` on `push: main`, and `terraform-apply-workload.yml` / `terraform-teardown-workload.yml` on `workflow_dispatch` with environment gates. The OIDC `sub` claim already differentiates these triggers — `pull_request`, `ref:refs/heads/main`, `environment:workload-apply`, `environment:workload-teardown`. ADR-009 chose this split for cost and review reasons; ADR-029 leverages the same split as the natural axis for IAM identity differentiation.

A full inventory of Terraform-controlled IAM roles in the repo (15 distinct types) shows that 12 are already minimal — the four `github-actions-aegis-core-*` roles (gold-standard pattern with `job_workflow_ref` pinning + scoped inline policies), the FIS service role (managed policy intersected with an inline `Deny non-Karpenter`), the EKS cluster / Fargate / Karpenter-node roles (canonical AWS managed policies), the Karpenter-controller / aws-load-balancer-controller / external-secrets / aegis-engine IRSA roles. Only the three `github-actions-terraform` roles are over-privileged. The scope-down work is bounded to these three.

## Decision

Replace each `github-actions-terraform` role with **four purpose-scoped roles per account**, keyed off the OIDC `sub` claim that already differentiates the four CI triggers.

### 4-role split (per account)

| New role | Trust `sub` claim | Permission character | Risk if token leaked |
|---|---|---|---|
| `gh-tf-plan` | `pull_request` | Read-only — broad `Describe* / List* / Get*`, plus state-object read, state-lock writes scoped to `*.tflock` suffix, and KMS via S3 conditioned `Decrypt` / `GenerateDataKey` | Recon only — AWS metadata disclosure, which CLAUDE.md classifies as not-secret |
| `gh-tf-apply-baseline` | `ref:refs/heads/main` | Org / IAM / SSO / SCP / IPAM / state-bucket / Cognito / CloudFront / Route53 / ACM / SSM / KMS — service-namespace scoped to `aegis-*` resource ARN patterns | Org-level mutation; gated by branch protection and required reviews on `main` |
| `gh-tf-apply-workload` | `environment:workload-apply` | EC2 / VPC / EKS / ELB / cluster-IAM / Logs / SQS / Events — workload-tier scope with tag-conditioned mutation where supported | Cost-incurring resource creation; gated by environment required-reviewer + main-only deployment branches |
| `gh-tf-teardown-workload` | `environment:workload-teardown` | Same service surface as apply-workload, action list narrowed to `Delete* / Detach* / Disassociate* / Terminate* / Schedule* / Disable* / Remove*` plus the read shapes the teardown workflow's safety-net steps need | Destructive; same env-approval gate as apply-workload |

The unlocking move is `gh-tf-plan` as **read-only**. A fork-PR attacker who hijacks `pull_request` workflow execution and successfully exfiltrates an OIDC token can at most run `terraform plan` — which produces metadata disclosure but cannot change anything. This eliminates fork-PR-OIDC as a meaningful blast-radius source even before Layer 0 is considered.

### Per-account scope

Role existence follows workflow-trigger scope, not blanket symmetry:

- `gh-tf-plan` lands in `aegis-management` + `aegis-shared` + `aegis-staging`. `terraform-plan.yml` runs a matrix across all three baseline accounts on every PR.
- `gh-tf-apply-baseline` lands in `aegis-management` + `aegis-shared` + `aegis-staging`. `terraform-apply-baseline.yml` matrix mirrors the plan workflow.
- `gh-tf-apply-workload` lands in `aegis-staging` only. `terraform-apply-workload.yml` is `workflow_dispatch` with an `env` input that resolves to a single account; today only `staging` is wired. Future `prod` adds the role in `aegis-prod` at that point.
- `gh-tf-teardown-workload` lands in `aegis-staging` only, same reasoning.

Total: 8 role-policy pairs at steady state. The plan-tier API surface differs across accounts (mgmt has Org / SSO / SCP reads, shared has IPAM, staging has EKS / ELB), but the role *shape* — purpose-scoped, sub-claim pinned, inline policy — is identical across instances of the same role.

### 12 already-minimal roles unchanged

The four `github-actions-aegis-core-*` roles, the FIS service role, the EKS cluster / Fargate / Karpenter-node roles, and the four IRSA roles are not modified by this ADR. Their inventory and disposition are documented in Appendix A.1 for completeness.

### Rollout

The aggressive bundling option is chosen — one PR per role family, covering all three accounts in a single change. Per-family rollout combines new-role creation, scoped policy attachment, and workflow `role-to-assume` cutover into one merge. The conservative four-PR-per-family-per-account variant (build with Admin → swap to scoped → cutover workflow → delete old role) is rejected as over-segmented for a solo operator with a finite session window; the bundled variant is independently revertible (one PR revert restores the prior role) and cuts the rollout from ~16 PRs to 5.

Family priority by blast-radius reduction:

1. `gh-tf-plan` — closes fork-PR-OIDC as an attack class. Highest leverage.
2. `gh-tf-apply-workload` — second largest blast surface (NAT Gateway, EKS, ALB cost-incurring resources).
3. `gh-tf-teardown-workload` — destructive verbs split from apply, smaller policy.
4. `gh-tf-apply-baseline` — moderate; already gated by branch protection on `main`.
5. Cleanup PR — drop `AdministratorAccess` and delete the old `github-actions-terraform` resource in all three accounts.

Family-by-family serial sequencing. Each PR's CI plan output is inspected for unexpected diffs (resources outside the IAM role/policy surface, plan-time state writes — see OQ-3) before the next family ships. A failure in any family stops the cascade.

Stop-loss conditions during rollout, in order of severity:

- A new family's CI plan reveals diff on resources outside the role/policy surface.
- A `terraform plan` run after `gh-tf-plan` ships unexpectedly writes the state object (validates OQ-3 contingency).
- Any layer fails apply with `AccessDenied` after a workflow `role-to-assume` cutover.
- Two consecutive PRs fail CI plan.

Any of these triggers a halt, an Incident draft, and a wait for human review.

## Alternatives Considered

### A. Keep `AdministratorAccess` and rely on Layer 0 alone

Rejected. Layer 0 is solid but represents a single class of failure surface. Compromised maintainer credentials, GitHub-side approval-gate bug, or a settings drift episode (the kind ldz#170's `workload-apply` `deployment_branch_policy: null` was caught as) would all turn an Admin token into a full-account compromise. A public portfolio repo that claims security discipline cannot rest its entire wall on a single layer of GitHub repo settings, however well configured.

### B. Split by Terraservice layer (one role per network / platform / workloads / observability)

Rejected. Doesn't align with the OIDC `sub` claim differentiation, which is the natural cleavage. Misses the unlocking move — `gh-tf-plan` read-only applies across all layers and would have to be replicated per layer if split this way. Also produces N×3 roles where 4×3 suffices.

### C. Per-account differentiation only (scope down the existing role per account, no split)

Rejected. Would still leave one role per account handling both `pull_request` reads and `ref:refs/heads/main` writes. The fork-PR-OIDC bound from "Admin" to "what this account's role can do" is real but does not reach the bound from "writes" to "reads only." The unlocking move is sub-claim-keyed, not account-keyed.

### D. Defer until production deployment ("not a real lab problem")

Rejected. This is a public portfolio repo; the audit trail is itself part of the artifact. A hypothetical reviewer (interviewer, forker, future-me) reading `oidc-github.tf` would correctly conclude that the threat model section of CLAUDE.md is aspirational rather than implemented. The work is not large, the rollout is bounded, and shipping the discipline matters more than waiting for a production trigger that the lab does not have.

## Consequences

### Makes easier

- Fork-PR-OIDC stolen-token impact is bounded to AWS metadata disclosure. The largest credential-related class of public-repo risk is closed.
- Each CloudTrail `AssumeRoleWithWebIdentity` event identifies the *purpose* of the assumption, not just "Terraform CI." Audit trail goes from "github-actions-terraform did X" to "the plan role did X" / "the workload-apply role did X" — meaningfully more useful for forensic work.
- The four `github-actions-aegis-core-*` roles already use this pattern (purpose-scoped, sub-claim pinned, inline policy with `job_workflow_ref` where applicable). After ADR-029, every Terraform-controlled `github-actions-*` role in the repo follows the same shape. No more "this role is the exception."
- A new layer touching a new AWS service produces a clear signal at the policy boundary: the matching apply-tier role rejects the action with `AccessDenied` until its policy is extended. This becomes a checklist item in `docs/principles/change-review-discipline.md` (per Open Question 7).

### Makes harder

- 8 role-policy pairs to keep aligned, vs 3 today (`gh-tf-plan` + `gh-tf-apply-baseline` in 3 accounts each = 6, plus `gh-tf-apply-workload` + `gh-tf-teardown-workload` in `aegis-staging` only = 2). Drift between accounts is now possible. Mitigation: shared module pattern in `terraform/modules/github-oidc-roles/` is a candidate future refactor but explicitly out of scope here — the per-account `oidc-github.tf` files diverge enough on plan-tier API surface that abstracting prematurely would obscure rather than clarify.
- Rollout sequencing matters. A family PR that updates the workflow `role-to-assume:` before its corresponding role exists in main will fail CI on the very next PR's plan run. The 4-PR conservative variant would have separated those steps; the bundled variant requires the same PR's diff to be self-consistent, verified by reviewing the CI plan output before merge.
- The change-review discipline doc gains a new checklist line (per OQ-7). Forkers reading the principles doc see one more item to satisfy when adding a layer.

### Risks

- `terraform plan -refresh=true` (Terraform's default) may write to the state object during refresh. This would break the `gh-tf-plan` read-only design. Mitigation in OQ-3: the rollout's first PR includes `s3:PutObject` on the state-key suffix as a worst-case guard; if empirical observation shows `plan -refresh` does not write state under our backend configuration, a follow-up PR tightens the policy.
- Adding a new AWS service in a future layer produces `AccessDenied` at first apply if the apply-tier policy has not been extended. Failure is loud (CI fails, no silent corruption), but it is a known operational tax.
- Trust policy refinements that would help against "main got compromised + new workflow file added" (Layer 2 `job_workflow_ref` pinning) are not part of this ADR. They are decorative against fork-PR specifically but do help against post-merge-attacker-on-main; a follow-up ADR or a low-priority PR can add them.

## Open Questions

All seven have resolutions; none block transition to Accepted.

1. **LB controller policy granularity** — keep the canonical kubernetes-sigs JSON (broader than strictly used; covers WAFv2 / Shield surface unused) vs scope to actually-used actions. **Resolved: stay-canonical.** Zero forker cost, drift-tracked at chart bumps, no maintenance debt for marginal blast-radius reduction.
2. **`gh-tf-teardown-workload` and `iam:CreateServiceLinkedRole`** for `spot.amazonaws.com` and `eks.amazonaws.com`. **Resolved: retain.** AWS auto-recreates these SLRs during destroy under conditions that are not predictable from baseline state; requiring a baseline pre-create would invert the dependency direction.
3. **`terraform plan -refresh=true` and state-file writes.** **Resolved: empirically test in PR-1 rollout; ship `gh-tf-plan` policy with `s3:PutObject` on state-key suffix as worst-case guard.** If post-PR-1 verification shows `plan -refresh` does not write state under our S3 + native locking backend, a follow-up PR removes the `PutObject`. If it does write, the policy stands and a Layer 5 detective control alarms on unexpected `PutObject` events from the plan role.
4. **`job_workflow_ref` parity on the four `aegis-core-*` CI roles** — `cache` and `cognito-integration` lack the pin that `ecr` and `frontend` have. **Resolved: add for parity in a low-priority follow-up PR.** Defense-in-depth against post-merge-attacker-on-main; not blocking ADR-029.
5. **Should `gh-tf-plan` exist in mgmt + shared + staging, or only staging?** **Resolved: all three accounts.** mgmt and shared have smaller plan-time API surface than staging, but their fork-PR exposure is identical and their privilege ceiling is higher (Org-level). Uniformity across accounts beats marginal LOC savings.
6. **Rollout cadence — 16 PRs over ~3 sessions vs aggressive bundle.** **Resolved: aggressive bundle, ~5 PRs.** Solo operator with a finite session window; bundled PRs are independently revertible at the role-family granularity; the four-PR-per-family-per-account variant is over-segmented for the actual operational constraints.
7. **Add Apply-tier-permission-update checklist line to `docs/principles/change-review-discipline.md`.** **Resolved: add.** When a new layer touches a new AWS service, the matching apply-tier policy must be extended in the same PR; this becomes part of the 5-step pre-merge audit.

## Related

- [ADR-009](009-lifecycle-and-teardown-strategy.md) — established the four-trigger CI workflow split that ADR-029 leverages as the natural axis for IAM identity differentiation.
- [ADR-002](002-region-restriction.md) — sibling guardrail at the SCP layer; orthogonal to this ADR's identity layer but composes — even a compromised apply-tier token cannot operate outside `eu-central-1` / `eu-west-1`.
- [aegis-core#112](https://github.com/BinHsu/aegis-core/issues/112) and [ldz#170](https://github.com/BinHsu/aegis-aws-landing-zone/issues/170) — Layer 0 cross-repo coordination, both closed 2026-05-03; the external wall this ADR's internal wall complements.
- CLAUDE.md *"What is NOT a secret"* clause — the threat-model premise that account IDs and role ARNs are public-by-design and the wall must therefore live at STS / IAM, not at obscurity.
- `docs/principles/change-review-discipline.md` — gains a new checklist line per OQ-7 (separate PR, not bundled).

## Appendix

### A.1 Inventory of Terraform-controlled IAM roles

15 distinct role types. 12 already minimal — no ADR-029 action. 3 over-privileged — replaced by ADR-029.

| # | Role name | Account | File | Trust (one-line) | Permission today | Disposition |
|---|---|---|---|---|---|---|
| 1 | `github-actions-terraform` | `aegis-management` | `terraform/environments/management/bootstrap/oidc-github.tf` | OIDC, sub ∈ {main, pull_request} | `AdministratorAccess` | Replaced by 4-role split |
| 2 | `github-actions-terraform` | `aegis-shared` | `terraform/environments/shared/bootstrap/oidc-github.tf` | OIDC, sub ∈ {main, pull_request} | `AdministratorAccess` | Replaced by 4-role split |
| 3 | `github-actions-terraform` | `aegis-staging` | `terraform/environments/staging/bootstrap/oidc-github.tf` | OIDC, sub ∈ {main, pull_request, env:workload-apply, env:workload-teardown} | `AdministratorAccess` | Replaced by 4-role split |
| 4 | `github-actions-aegis-core-ecr` | `aegis-staging` | `terraform/environments/staging/bootstrap/oidc-aegis-core.tf` | OIDC, aegis-core/main + `job_workflow_ref` pinned | inline ECR push to single repo | Already minimal |
| 5 | `github-actions-aegis-core-cache` | `aegis-staging` | `terraform/environments/staging/bootstrap/oidc-aegis-core.tf` | OIDC, aegis-core/main | inline S3 R/W on Bazel cache bucket | Already minimal (OQ-4: add `job_workflow_ref` pin in follow-up) |
| 6 | `github-actions-aegis-core-frontend` | `aegis-staging` | `terraform/environments/staging/edge/oidc-aegis-core-frontend.tf` | OIDC, aegis-core/main + `job_workflow_ref` pinned | inline S3 PutObject + CloudFront CreateInvalidation | Already minimal |
| 7 | `github-actions-aegis-core-cognito-integration` | `aegis-staging` | `terraform/environments/staging/auth/iam.tf` | OIDC, aegis-core/main | inline Cognito Admin\* on this pool + SSM read | Already minimal (OQ-4: add `job_workflow_ref` pin in follow-up) |
| 8 | `aegis-staging-fis-service` | `aegis-staging` | `terraform/environments/staging/fis/iam.tf` | `fis.amazonaws.com`, source-account + experiment-arn pinned | managed `AWSFaultInjectionSimulatorEC2Access` ∩ inline `Deny non-Karpenter` | Already minimal |
| 9 | `<cluster>-eks-cluster-role` (×K) | `aegis-staging` | `terraform/environments/staging/platform/modules/eks-cluster/cluster.tf` | `eks.amazonaws.com` | managed `AmazonEKSClusterPolicy` + `AmazonEKSVPCResourceController` | Already minimal (canonical) |
| 10 | `<cluster>-fargate-pod-execution-role` (×K) | `aegis-staging` | `terraform/environments/staging/platform/modules/eks-cluster/fargate.tf` | `eks-fargate-pods.amazonaws.com` | managed `AmazonEKSFargatePodExecutionRolePolicy` | Already minimal (canonical) |
| 11 | `<cluster>-karpenter-node` (×K) | `aegis-staging` | `terraform/environments/staging/platform/modules/eks-cluster/karpenter-iam.tf` | `ec2.amazonaws.com` | WorkerNode + CNI + ECR-RO + SSM-Core managed | Already minimal (canonical) |
| 12 | `<cluster>-karpenter-controller` (×K) | `aegis-staging` | `terraform/environments/staging/platform/modules/eks-cluster/karpenter-iam.tf` | IRSA, `karpenter:karpenter` | inline canonical Karpenter v1 scoped by cluster tag + region + SQS | Already minimal |
| 13 | `<cluster>-aws-lb-controller` (×K) | `aegis-staging` | `terraform/environments/staging/platform/modules/eks-cluster/lb-controller-iam.tf` | IRSA, `kube-system:aws-load-balancer-controller` | inline canonical kubernetes-sigs JSON | Already minimal (OQ-1: stay canonical) |
| 14 | `<cluster>-external-secrets` (×K, count-gated) | `aegis-staging` | `terraform/environments/staging/platform/modules/eks-cluster/external-secrets-iam.tf` | IRSA, `external-secrets:external-secrets` | inline SSM `/aegis/staging/grafana-cloud/*` + KMS-via-SSM | Already minimal |
| 15 | `<cluster>-aegis-engine` (×K) | `aegis-staging` | `terraform/environments/staging/workloads/modules/eks-workloads/irsa.tf` | IRSA, `aegis:aegis-engine` | none yet (skeleton) | Already minimal (by absence) |

### A.2 `gh-tf-plan` policy sketch (read-only)

The policy ships in the rollout's first PR. Region tokens are `${primary_region}` placeholders consistent with the CLAUDE.md zero-tolerance rule; the actual `.tf` will interpolate from `local.primary_region` / `local.dr_region`.

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
      "Resource": "arn:aws:s3:::aegis-terraform-state-345895787808/*",
      "Condition": {
        "StringEquals": {"aws:SourceVpce": "<unused — placeholder>"}
      }
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
        "eks:Describe*", "eks:List*",
        "s3:GetBucket*", "s3:ListAllMyBuckets",
        "kms:Describe*", "kms:List*", "kms:GetKeyRotationStatus", "kms:GetKeyPolicy",
        "organizations:Describe*", "organizations:List*",
        "sso-admin:Describe*", "sso-admin:List*", "sso-admin:Get*",
        "identitystore:Describe*",
        "ssm:Describe*", "ssm:Get*", "ssm:List*",
        "logs:Describe*", "logs:List*",
        "sqs:Get*", "sqs:List*",
        "events:Describe*", "events:List*",
        "ram:Get*", "ram:List*",
        "ipam:Describe*",
        "fis:Get*", "fis:List*",
        "cognito-idp:Describe*", "cognito-idp:List*", "cognito-idp:Get*",
        "cloudfront:Get*", "cloudfront:List*",
        "acm:Describe*", "acm:List*",
        "route53:Get*", "route53:List*",
        "ecr:Describe*", "ecr:Get*", "ecr:List*",
        "elasticloadbalancing:Describe*",
        "tag:Get*"
      ],
      "Resource": "*"
    }
  ]
}
```

`Resource: "*"` on the last statement is acceptable because every action is read-only. The threat model classifies the metadata revealed as not-secret. The deny floor for the role is "no mutation outside the state-lock suffix and the worst-case state-write guard."

The `WriteStateOnRefreshGuard` statement is a placeholder that ships disabled (no real `aws:SourceVpce` configured); it documents the worst-case path for OQ-3 and is replaced with either an unconditional `s3:PutObject` on the state-key suffix or removal entirely after PR-1's empirical test.

### A.3 Apply-tier policy outlines

Full JSON for `gh-tf-apply-baseline`, `gh-tf-apply-workload`, and `gh-tf-teardown-workload` lands in their respective rollout PRs. The structural rules are documented here:

- **Resource ARNs**: explicit `aegis-*` prefix or account-scoped `arn:aws:<svc>::<account>:`. No `Resource: "*"` for Create / Update / Delete actions.
- **Region tokens**: always `${primary_region}` / `${dr_region}` interpolation, never literal `eu-central-1` (CLAUDE.md zero-tolerance rule).
- **Tag conditions**: `aws:ResourceTag/Project = landing-zone-lab` and `aws:ResourceTag/Environment = <env>` on Create / Update / Delete where the service supports condition keys.
- **Service surfaces** are derived from the Terraservices each role's workflow trigger applies. Baseline covers `management/{bootstrap,scps}` + `shared/{bootstrap,ipam}` + `staging/{bootstrap,secrets-persistent,auth,edge}`. Apply-workload covers `staging/{network,platform,workloads,observability,fis}`. Teardown-workload covers the same surfaces with action lists narrowed to destructive verbs plus the read shapes needed by the workflow's safety-net steps.
- **One inline policy per role per account**. Bundling the union of services into a single policy per role (vs splitting per layer within a role) keeps the policy file colocated with its `aws_iam_role` resource and avoids cross-file lookup during review.
