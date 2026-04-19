<!-- session-close-review: Grafana auth status (local admin only vs SSO wired) + referenced runbook existence still accurate -->
# 009. Grafana SSO integration

## Current state

Grafana is deployed via `kube-prometheus-stack` Helm chart (ADR-015). Authentication today:

| Mechanism | Status |
|---|---|
| Local admin account | ✅ enabled by default — currently the **only** auth path |
| Admin password source | `random_password` Terraform resource; exposed as sensitive output `grafana_admin_password` on `staging/workloads` (from PR #78) |
| SSO / OIDC / SAML | ❌ not configured |
| `grafana.admin.disableLogin` | ❌ not set (local admin login is active) |

Access pattern today: `kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80`, then browser login with user `admin` + the password from `terraform output`.

## Gap / risk

| Failure mode | Impact | Frequency |
|---|---|---|
| Operator keeps logging in as `admin` because there is no alternative | Audit log names only "admin"; no per-user attribution | Every session |
| Password is stored in TF state only | Operator who loses state access loses Grafana | Rare but recoverable only by reapply (which rotates the password) |
| New team member cannot be granted Grafana access without sharing the admin password | Hard blocker for multi-operator scale | Would hit at first team expansion |
| Break-glass and daily auth collapsed into one credential | Admin password is "hot" — used daily — rather than kept cold for emergencies | Structural |

The credential is not currently at elevated risk (one-operator lab, ClusterIP access via port-forward), but the *auth model* is the issue. A single shared local admin is the auth anti-pattern ADR-013 consciously avoided for EKS (which went API-only Access Entries → SSO). Grafana is the remaining hole.

## Threat addressed

This entry is less about an external threat and more about auth-model consistency. The whole repo enforces SSO-for-humans / OIDC-for-CI / IRSA-for-workloads. Grafana is the only interactive surface that does not.

## Scope

**Grafana authentication only.** Prometheus is not a user-facing UI; Alertmanager is disabled (ADR-015). So "Grafana SSO" is the whole scope of the user-facing observability auth gap.

## Target design

Two viable SSO paths:

### Option A: AWS IAM Identity Center (SAML)

Grafana has a first-party SAML integration. Identity Center already hosts this lab's humans (SSO start URL is in `config/landing-zone.yaml`). Flow:

1. Create a SAML application in Identity Center named "Grafana staging".
2. Assign SSO groups (e.g., `aegis-platform-admins`, `aegis-viewers`) to the application.
3. In Grafana Helm values, set `grafana.ini.auth.saml.*` with the Identity Center metadata URL + cert.
4. Map SSO group → Grafana role via `role_values_admin` / `role_values_editor` / `role_values_viewer`.
5. Set `grafana.admin.disableLogin = true` — local admin login disappears entirely.
6. The `random_password` resource and its output remain, but the password is never used in normal operation. It becomes the documented break-glass if SAML provider is unreachable.

### Option B: GitHub OAuth

Grafana's `auth.generic_oauth` works with GitHub. Simpler to set up (no SAML metadata), but ties operator identity to GitHub accounts rather than the lab's canonical IdP. Acceptable for a lab with one operator; awkward if team scale arrives.

### Recommendation

**Option A**. Identity Center is already the IdP for everything else. Using it for Grafana makes the auth story uniform: one IdP, one set of groups, one MFA story. Option B is a fallback if Identity Center SAML app provisioning turns out to be painful via Terraform.

## Prerequisites

1. Identity Center has at least one permission set / group that can be mapped to Grafana admin (the current `AWSReservedSSO_PlatformAdmin` role maps naturally).
2. `aws_ssoadmin_application` + `aws_ssoadmin_application_assignment` resources — or manual provisioning — depending on how much Terraform can do for SAML apps as of the implementation date.
3. Grafana accessed via a stable URL. Current `kubectl port-forward` works for a single operator; a real SAML callback needs a stable URL (ALB + ACM + Route 53). This is a sub-prerequisite and may land first as its own small PR.

## Reversibility

Fully reversible. Removing `grafana.ini.auth.saml.*` and setting `grafana.admin.disableLogin = false` restores local admin login. No data migration.

## Cost estimate

| Component | Cost |
|---|---|
| SAML app in Identity Center | $0 |
| Grafana ALB + ACM cert (if stable URL is added as prerequisite) | ALB ~$16/month persistent if left up; ACM free |
| Operator time | ~2 hours (Terraform for app + assignment, Helm values, test login) |

The ALB cost is the main gotcha. Mitigation: ALB is torn down with the rest of the workloads layer (`terraform-teardown-workload.yml`). Monthly cost during inactive periods is $0.

## Operational burden

Negligible once configured. Identity Center group assignments become the admin interface; Grafana values do not need to change as team composition changes.

## Validation plan

1. Apply the Terraform change.
2. Open Grafana via port-forward; confirm local admin login is **disabled** (login form redirects to Identity Center).
3. Log in as the operator's SSO identity; confirm Grafana role (Admin/Editor/Viewer) matches SSO group mapping.
4. Try the break-glass path: set `grafana.admin.disableLogin = false` temporarily in a test apply, confirm password from `terraform output` still works. Revert.
5. Drill: open a fresh incognito browser, SSO login, verify access.

## Portfolio angle

1. **Uniform auth model** — SSO everywhere (AWS Console, Grafana, eventually ArgoCD) closes the "last local account" gap that most teams leave open indefinitely.
2. **Break-glass done right** — admin password continues to exist and be retrievable, but `disableLogin = true` makes it structurally unusable for routine access. "Exists for emergencies only" is encoded in the configuration, not just the documentation.
3. **Reuses existing IdP** — no extra identity system, no extra credential sprawl.

## Deferred / out of scope

- **ArgoCD SSO integration**. Same pattern; different surface. Warrants its own entry (probably #010) once this one ships.
- **Prometheus auth**. Prometheus UI is accessed by operators for PromQL debugging; same port-forward, same lack of SSO. Lower priority than Grafana because it is not used daily.

## Lab status

Not started. PR #78 landed the `random_password` + sensitive output foundation; this entry describes what to build on top of it.
