# 031. Tier 3 Detective Controls

## Status

Accepted (2026-05-04). Item A implemented in this PR; items B and C Accepted with implementation deferred to follow-up PRs.

## Context

[ADR-029](029-iam-permission-scope-down.md) closed Tier 1 — the over-privileged `github-actions-terraform` role was replaced by four purpose-scoped roles per account, keyed off the OIDC `sub` claim. [ADR-030](030-tier-2b-permission-boundary-hardening.md) closed Tier 2B — the SCP `deny-iam-privilege-escalation` plus the state bucket allow-list and OIDC `repository_id` claim raised the inner wall against the apply-tier-to-Admin privilege-escalation primitive. Together those tiers form the **preventive** layer of the fork-PR-OIDC + privilege-escalation defense.

Tier 3 is the **detective** layer. It is asymmetric to the preventive tiers: it does not stop an attack, it surfaces one. The threat model that motivates it:

- A fork PR slips past Layer 0 (rare, but past 24-hour drift in [ldz#170](https://github.com/BinHsu/aegis-aws-landing-zone/issues/170)'s `deployment_branch_policy: null` showed it is possible).
- The fork attempts `sts:AssumeRoleWithWebIdentity` against one of the four `gh-tf-*` roles.
- The trust policy's `:sub` claim check rejects the assumption — Tier 1 wall holds.
- CloudTrail logs an `AccessDenied` STS event.
- **Without alerting, this event sits in the Control Tower S3 archive unread.**

The next operator (including future-Bin) finds out only by chance — searching CloudTrail months later for an unrelated reason. By then the attacker has either already pivoted or gone quiet. The detective layer's job is to convert "attempted breach" into a same-hour notification so the operator can investigate while the trail is fresh.

A second motivating event class: `iam:CreateRole` / `iam:AttachRolePolicy` / `iam:PutRolePolicy` denials surfaced by ADR-030's SCP. If the apply-tier role's identity is ever used in a way that trips the SCP — by an attacker or by a buggy Terraform plan — the same alerting need applies. That class is documented as Item C below; this PR ships only Item A (the OIDC-failure case).

### Architecture: EventBridge over CloudWatch Logs metric filter

CloudTrail in this org is provisioned by AWS Control Tower. The trail is org-wide, KMS-encrypted with `alias/aegis-control-tower-key`, and archives to an S3 bucket in `aegis-logarchive`. The trail is **CT-managed — do not modify**. Two paths to alerting:

| Path | Pros | Cons |
|---|---|---|
| CloudWatch Logs metric filter on CT log group | Standard pattern, supports complex pattern matching, history queryable via Logs Insights | Requires CT trail to send to CWL (it does not by default); would need a SECOND trail at ~$2/mo per account, ~$12/mo across the six-account org |
| **EventBridge rule directly on CloudTrail events** | Free for AWS-source events, no second trail, simpler IaC, lower-latency than CWL flush | Per-account scope (each account's EventBridge sees only its own events), no historical replay, pattern matching is JSON-only (no full regex) |

**Decision: EventBridge.** The per-account scope is acceptable for MVP because the management account is the highest-leverage target — org-mutating actions (`organizations:*`, `sso:*`, attaching SCPs, mutating IAM trust policies) all originate there. The mgmt account is also where the four `gh-tf-*` roles live, so a fork-PR-OIDC attempt against any of those four trips an STS event in the mgmt-account event bus. Per-account scope means the rule sees mgmt's local STS events only — an attempted assumption against `aegis-staging`'s cross-account roles would be invisible. That is acceptable for MVP and is the explicit deferral in Item B.

CloudWatch Logs metric filter is the more featureful path but its cost — and more importantly its requirement to provision a second org trail to CloudWatch Logs in parallel with the CT-managed trail — makes it the wrong choice for an MVP that just wants to know "was a denied OIDC assumption attempted today?"

### Why not GuardDuty + EventBridge

GuardDuty IS deployed in `staging/platform/` (per [ADR-013](013-eks-architecture.md)). It is the right tool for runtime threat detection — anomalous instance behavior, container escapes, credential exfiltration patterns. It is **not** the right tool for "alert me when an OIDC trust policy is exercised in an expected-deny shape." GuardDuty findings are tuned to high-confidence anomalies; a routine fork-PR-OIDC attempt is at best a low-confidence finding (it could be a misconfigured legitimate workflow) and at worst silently filtered. The detective control wanted here is deterministic: every `errorCode` on an `AssumeRoleWithWebIdentity` event triggers the alert, no ML, no tuning. EventBridge with a literal pattern match is the deterministic shape.

GuardDuty also has a meaningful runtime cost (~$5-10/mo per account for the workload-tier feature set in EKS) that is hard to justify for the detective-control purpose alone. It earns its keep on the runtime side.

## Decision

| Item | Layer | Action | Status |
|---|---|---|---|
| A | EventBridge | Rule on failed `AssumeRoleWithWebIdentity` in mgmt account → SNS → email | **SHIPPED in this PR** |
| B | EventBridge | Same rule deployed to staging + shared accounts (multi-account event surface) | DEFERRED |
| C | EventBridge | SCP-denied IAM mutation alert on `iam:Create*` / `iam:Put*` / `iam:Attach*` / `iam:PassRole` with `errorCode ∈ {AccessDenied, AccessDeniedException}` and principal not in allow-list | DEFERRED |

### A. EventBridge rule on failed OIDC assumption (SHIPPED)

A new file `terraform/environments/management/bootstrap/detective-controls.tf` lands the following resources:

- `aws_sns_topic.security_alerts` — name `aegis-security-alerts`, KMS-encrypted with `alias/aws/sns` (the AWS-managed SNS key — see Open Question 1). Standard `local.tags`.
- `aws_sns_topic_subscription.security_alerts_email` — protocol `email`, endpoint `local.config.budget.alert_emails[0]`. The first email in the list reuses the budget-alerts mailbox; one less config field for forkers (see Open Question 2). The subscription is created in `Pending Confirmation` state; AWS sends a confirmation email to the endpoint, the operator clicks the link once, and the subscription becomes `Confirmed`. Until confirmation, alerts queue but are not delivered. The `terraform apply` succeeds regardless of the confirmation state.
- `aws_cloudwatch_event_rule.failed_oidc_assumption` — pattern matches `source: aws.sts` + `detail-type: AWS API Call via CloudTrail` + `eventName: AssumeRoleWithWebIdentity` + `errorCode: {exists: true}`. The `errorCode` exists-test is the simplest deterministic shape that catches every denial mode (AccessDenied, AccessDeniedException, NotAuthorizedException, MalformedPolicyDocument, etc.) without the rule needing to enumerate them.
- `aws_cloudwatch_event_target.failed_oidc_assumption_to_sns` — fans the rule to the SNS topic. Includes an Input transformer so the email body reads `"AEGIS DETECTIVE: Failed OIDC assumption at <eventTime> from <sourceIp> by <principalId>. Error: <errorMessage>"` instead of the raw 2KB CloudTrail JSON. The transformer is small (4 input paths + 1 template line); the readability win is worth the lines.
- `aws_sns_topic_policy.security_alerts` — allows EventBridge service principal `events.amazonaws.com` to publish to the topic, conditioned on `aws:SourceArn` equaling the EventBridge rule's ARN. Least-privilege: only this specific rule can publish, not any EventBridge rule in the account.

### B. Same rule deployed to staging + shared accounts (DEFERRED)

The mgmt-account-only scope of Item A means cross-account `gh-tf-*` role assumptions targeting staging or shared are not surfaced. Adding the same EventBridge rule to those accounts would fan their events into independent SNS topics + email subscriptions. Trade-off: more SNS topics (one per account, each with its own pending-confirmation email link), more alert sources to mentally aggregate, slightly higher operator cognitive load. For MVP, the mgmt-account event surface is the highest-leverage target; multi-account deployment graduates from "deferred" to "Item B PR" if the detective layer ever surfaces evidence of a cross-account assumption attempt that mgmt's rule missed.

Implementation when materialized: add `terraform/environments/staging/bootstrap/detective-controls.tf` and `terraform/environments/shared/bootstrap/detective-controls.tf` with the same shape, parameterized by the per-account email list (which today is uniform across `local.config.budget.alert_emails[0]` — a future split might give each account its own mailbox).

### C. SCP-denied IAM mutation alert (DEFERRED)

A second EventBridge rule on `eventName ∈ {CreateRole, AttachRolePolicy, PutRolePolicy, CreateUser, AttachUserPolicy, PassRole}` AND `errorCode ∈ {AccessDenied, AccessDeniedException}` AND principal NOT in the same allow-list ADR-030's SCP uses (Control Tower / StackSets / `gh-tf-*` / `aegis-emergency-*` / Karpenter). The pattern match on principal-arn is the higher-complexity bit — EventBridge's JSON-pattern matching supports `anything-but` and `prefix` operators on string fields but the construction is verbose. The same effect can be achieved more elegantly via Logs Insights queries on the CT trail, which suggests Item C may end up as a CloudWatch Logs metric filter pattern (the second-trail cost is amortized across both Items B and C if both ship at the same time).

Deferred because the construction is non-trivial and the value is incremental over Item A — Item A catches the trust-policy bypass attempts; Item C catches the post-bypass escalation attempts. The escalation surface is already closed by ADR-030's SCP at the prevent layer, so Item C is the second-line detection that confirms the SCP is doing its job. Useful, not urgent.

## Alternatives Considered

### A1. Rely on Control Tower's existing trail + S3 logs (no live alert)

Rejected. The CT trail is the authoritative audit log, but it is read-only from the operator's perspective unless someone explicitly queries it. The detective control's purpose is exactly to remove the "someone has to remember to query" step. Without alerting, the trail is forensic evidence, not detection. Same data, different time-to-notice.

### A2. Second org trail to CloudWatch Logs with metric filter

Rejected for MVP. CloudWatch Logs metric filter is the standard pattern in AWS reference architectures (well-architected security pillar, CIS Benchmarks, etc.) and is the right answer at scale — it supports Logs Insights queries, full-regex pattern matching, and historical replay. The cost of running a second org trail is ~$2/mo per account for management events, and the CWL ingestion is another ~$0.50/GB. For a six-account org that is ~$15/mo of audit-only storage. Not large in absolute terms, but the EventBridge path costs $0/mo for the same MVP-shape detection. The CloudWatch Logs path graduates from "rejected" to "considered" if and when the detective layer needs Item C-class principal-allow-list pattern matching, which is genuinely awkward in raw EventBridge JSON.

### A3. GuardDuty + EventBridge on findings

Rejected for MVP, as detailed in Context. GuardDuty is a sibling layer (deployed in `staging/platform/`) for a different purpose (runtime threat detection). The ML-tuned finding shape is wrong for "deterministic alert on every `errorCode` on `AssumeRoleWithWebIdentity`."

### A4. Slack webhook instead of SNS email

Rejected for MVP. Slack webhook subscription requires either (a) an SNS-to-Slack Lambda (more moving parts, more IAM), (b) AWS Chatbot integration (account-level setup, narrower applicability for the lab), or (c) a direct SNS HTTPS subscription to a Slack incoming webhook URL. Option (c) is the simplest but Slack incoming webhook URLs are themselves secrets that would need SSM Parameter Store stashing per ADR-028. Email is a one-line subscription with no secret management. If the detective layer matures into Items B and C and the alert volume grows enough that email becomes noise, the path forward is documented Future Work below.

## Consequences

### Makes easier

- A fork-PR-OIDC attempt that fails Tier 1's trust-policy check generates a same-hour email alert. Operator notices within hours, not months.
- The audit trail of denied OIDC assumptions is queryable via the EventBridge rule's CloudWatch metrics (`MatchedEvents`) — operator can chart "denied-OIDC events per day" and notice burst patterns even without reading individual alerts.
- The SNS topic is reusable for Item B/C extensions. Adding the SCP-denied IAM mutation rule (Item C) is one more `aws_cloudwatch_event_rule` + one more `aws_cloudwatch_event_target` pointing at the same topic; the operator's email subscription handles both event classes.
- The detective layer makes the four-ADR progression (029 → 030 → 031) read as a coherent layered defense: 029 closes Tier 1 prevent, 030 closes Tier 2B prevent (inner wall), 031 closes Tier 3 detect.

### Makes harder

- One additional SNS subscription Bin must monitor. Single alert source is fine; if Items B and C both ship, the per-account topic count grows.
- Alert fatigue if the pattern catches expected denials. For example: a contributor temporarily breaks the OIDC trust policy via a PR (during an ADR-029-style refactor), CI runs `terraform plan`, the assumption fails, an alert fires. The PR's plan failure is the primary signal; the email is duplicate noise. Mitigation: the alert template names the source IP and principal, so the operator can recognize "this is my own CI run from a PR" within seconds of reading.
- A new permission scope on `gh-tf-apply-baseline` (mgmt account variant): `events:*` and `sns:*` scoped to the new rule + topic ARNs. This is a marginal expansion of the apply-tier role's surface; documented in Implementation Pointer below.

### Risks

- **SNS email throttle**: SNS limits email delivery to 24 emails per second per topic. If an attack burst (or a legitimately-broken CI loop) generates thousands of failed assumptions in a short window, alerts are throttled. Mitigation: the EventBridge rule's `MatchedEvents` metric is the source of truth for volume; the email is the human notification, not the audit log. CloudTrail remains the authoritative record.
- **SCP/role policy changes that legitimately deny actions trigger noise**: any future policy tightening that lands during a transition window can cause a flood of expected-deny alerts. This is the same risk profile as the change-review-discipline checklist's step 1 ("blast radius") — the operator answers "does this change generate detective-layer alerts?" at PR time and pre-warns the inbox.
- **Email subscription not confirmed**: AWS requires the operator to click a confirmation link in the welcome email. Until confirmed, the subscription is `Pending Confirmation` and alerts are silently dropped. The `terraform apply` succeeds regardless. Mitigation: the PR body's "Manual step" item documents this; the runbook for the layer (when materialized) will include a `aws sns list-subscriptions-by-topic` check as part of the apply post-flight.
- **No cross-account event visibility**: per Architecture above, mgmt-account-scope is acceptable for MVP but is a real gap. Items B closes it.

## Open Questions

1. **Does an SCP-denied event surface as `AccessDenied` from STS or from the IAM API itself?** Empirical confirmation needed. The hypothesis: SCP denial on `iam:CreateRole` surfaces as an `AccessDenied` on the IAM API, not on STS — the STS assumption succeeded, the IAM call after it is what got denied. The Item A rule (STS-only) does NOT catch SCP denials; Item C is needed for that surface. The first apply of this PR is the test case: when `terraform-apply-baseline.yml` runs, the role assumes via STS successfully (Tier 1 + Tier 2B both pass), then the apply itself runs `events:PutRule` etc. — if any of those trip the SCP, the rule won't fire (correct behavior — SCP denials are out of scope of Item A). A separate test would deliberately attempt an out-of-allow-list `iam:CreateRole` from `gh-tf-apply-baseline` and observe whether the event surfaces in mgmt's EventBridge bus at all.

2. **Should email go to `budget.alert_emails[0]` or a separate `security_alert_emails[0]` field?** Decision for MVP: reuse `budget.alert_emails[0]`. Rationale: forkers cloning this lab already have to populate `budget.alert_emails`; adding a `security_alert_emails` field is one more config-onboarding step for marginal benefit at MVP volume (estimated 0–1 alerts per week in steady state). The split graduates from "no" to "yes" if and when the alert volume crosses ~1 per day, at which point a dedicated mailbox or Slack channel is the right shape and `security_alert_emails` becomes the config field. Documented as future work; no schema change in this PR.

3. **KMS encryption of the SNS topic — `alias/aws/sns` vs a project CMK?** The mgmt account does not currently provision a project KMS key — the only project keys live in `shared/bootstrap/kms-state.tf` (state encryption) and `staging/bootstrap` (secrets). Using either of those for SNS would require cross-account KMS key policy edits, which is out of scope for an MVP detective control. `alias/aws/sns` (AWS-managed) is the chosen shape: encryption-at-rest is preserved, key rotation is AWS-handled, no cross-account complexity. Graduating to a project CMK is reasonable when the security account materializes a `security/bootstrap` layer (not currently planned). Documented as future polish.

## Future Work

- **Slack/PagerDuty integration**: when alert volume justifies it, replace the email subscription with an SNS-to-Slack Lambda (or AWS Chatbot). The SNS topic stays; only the subscription leg changes.
- **Items B + C**: as documented in Decision above. Item B is mechanical; Item C requires either a richer EventBridge pattern or a CloudWatch Logs metric filter (and the second-trail cost analysis).
- **EventBridge → CloudWatch metric**: add a CloudWatch metric alarm on `aws_cloudwatch_event_rule.failed_oidc_assumption`'s `MatchedEvents` metric so the rule itself triggers a CloudWatch alarm if any matched event lands. Belt-and-suspenders against the SNS email queueing-without-confirmation case.
- **Project CMK for SNS** when a mgmt-or-security KMS bootstrap layer materializes (Open Question 3).

## Related

- [ADR-029](029-iam-permission-scope-down.md) — Tier 1 (preventive). The trust-policy bypass attempts that this ADR's rule alerts on are exactly the ones Tier 1 rejects.
- [ADR-030](030-tier-2b-permission-boundary-hardening.md) — Tier 2B (preventive). The SCP denials that Item C would alert on are exactly the ones the SCP enforces.
- [ADR-005](005-compliance-framework-iso-27001.md) — ISO 27001 Annex A.8.16 ("Monitoring activities") is the compliance reference for this layer. Detective controls are an explicit ISO 27001 requirement; this ADR is the implementation evidence.
- [`docs/principles/change-review-discipline.md`](../principles/change-review-discipline.md) — step 1 (blast radius) gains an implicit "does this change generate detective-layer alerts?" line. Documented in the principle doc as the next amendment.
- [`docs/principles/break-glass-apply.md`](../principles/break-glass-apply.md) — break-glass actions are intentionally NOT alert-suppressed by this layer. A break-glass `aws iam put-role-policy` from `aegis-emergency-break-glass` is a normal API call (no SCP denial because the role is in the allow-list, no STS denial because the assumption is from PlatformAdmin SSO), so it produces no alert. This is correct behavior — break-glass leaves its trace in CloudTrail directly, not via the detective layer.

## Appendix A — Implementation Pointer

The PR ships:

- `docs/decisions/031-tier-3-detective-controls.md` — this file.
- `terraform/environments/management/bootstrap/detective-controls.tf` — the five resources detailed in Decision Item A. ~100 lines including header banner.
- `terraform/environments/management/bootstrap/oidc-github-baseline-role.tf` — adds two new Sids to the policy: `EventsForDetectiveRule` (events:* scoped to the rule ARN pattern) and `SnsForDetectiveTopic` (sns:* scoped to the topic ARN pattern). Marginal expansion of apply-baseline scope.
- `terraform/environments/management/bootstrap/oidc-github-plan-role.tf` — adds `events:Get*`, `sns:Get*`, `sns:List*` to the read-only Sid for plan-tier refresh / drift detection. The role already has `events:Describe*` and `events:List*`.

No other files modified by this PR.
