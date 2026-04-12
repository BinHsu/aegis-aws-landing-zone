# Runbook 001. Bootstrap AWS Account from Zero

This runbook walks through the complete bootstrap of the `aegis-aws-landing-zone` project, from "I have nothing" to "I can run Terraform against my management account via AWS IAM Identity Center with no long-lived credentials on disk." It is written to be followable from scratch by anyone forking the repository.

## Time and Cost

- **Time**: Approximately 2.5 hours total, of which ~60 minutes is waiting for AWS Control Tower to finish its initial provisioning.
- **Cost**: ~$10-15 for domain registration (one-time annual); AWS signup itself is free; the persistent baseline that runs after Control Tower is enrolled is approximately $5/month. See ADR-009 for the full cost model.

## Prerequisites

- A personal domain name (this project uses `binhsu.org` via Cloudflare Registrar). If you are forking, substitute your own domain everywhere.
- A Cloudflare account (free tier is sufficient).
- A credit card for AWS signup (AWS does a small pre-authorization, typically one US dollar).
- A phone capable of receiving SMS or a voice call for AWS identity verification.
- An authenticator app for MFA (Google Authenticator, Authy, 1Password, or Microsoft Authenticator all work).
- AWS CLI v2.15 or later installed locally. On macOS with Homebrew: `brew install awscli`. Verify with `aws --version`. If the version is below 2.15, run `brew upgrade awscli`. The SSO session configuration format used in Part 6 requires v2.15 or later; older versions use a deprecated format that does not support session-scoped SSO login.
- Terraform 1.10 or later installed locally. **Important**: Homebrew's default `terraform` formula is frozen at 1.5.7 (the last version before HashiCorp's BSL license change). You must use the HashiCorp tap to get a current version. On macOS with Homebrew: `brew tap hashicorp/tap && brew install hashicorp/tap/terraform`. If you previously installed from the default tap, uninstall first: `brew uninstall terraform` then install from the tap. Verify with `terraform --version`. Terraform 1.10 is required for S3 native state locking (`use_lockfile = true`) per ADR-003.

## Design Constraints

Before following the steps, understand the decisions baked into this runbook:

- The management account root user is touched only during initial bootstrap and break-glass scenarios. All routine operations go through AWS IAM Identity Center via `aws sso login`. See ADR-001 for the scope and the "no IAM users" principle.
- No long-lived credentials are ever written to `~/.aws/credentials`. If you find yourself creating IAM access keys, stop and re-read ADR-001.
- The home region is `eu-central-1` (Frankfurt) per ADR-002. Control Tower's home region is permanent once set, so this selection is load-bearing.
- Account names use the `aegis-*` prefix per ADR-006. The management account is `aegis-management`.

---

## Part 1: Domain and Email Routing

The landing zone uses a single personal-brand domain with Cloudflare Email Routing catch-all as the authoritative source for all AWS account ownership emails. See ADR-004 for rationale.

### 1.1 Register the domain

Log in to Cloudflare, navigate to **Domain Registration > Register Domain**, and purchase your domain. For a personal portfolio project, a three-year registration reduces the risk of accidental expiry. Confirm auto-renewal is enabled in the domain settings.

### 1.2 Enable Email Routing

Navigate to the domain's zone in Cloudflare, then **Email > Email Routing**. Enable Email Routing. Cloudflare automatically inserts the required MX records into the zone; do not edit them manually.

### 1.3 Add a destination address

Under **Destination Addresses**, add the inbox you actually read (for example, your personal Gmail). Cloudflare sends a verification email; click the link to confirm.

### 1.4 Create a catch-all rule

Under **Routing Rules**, add a **Catch-all address** rule with the action **Send to** pointing at your verified destination. This forwards every `*@your-domain.org` message to your real inbox.

### 1.5 Verify end to end

From a different email account, send a test message to `aws-aegis-management@your-domain.org`. Confirm it arrives in your inbox within a minute. **Do not proceed to Part 2 until this works.** If it does not, the DNS may still be propagating; wait five minutes and try again. If it still fails, recheck the catch-all rule and destination verification status.

---

## Part 2: AWS Account Signup

### 2.1 Navigate to signup

Open `https://signup.aws.amazon.com` in a browser session that is not logged into any existing AWS account.

### 2.2 Fill the signup form

- **Email**: `aws-aegis-management@your-domain.org` — the address you just verified in Part 1.
- **AWS account name**: `aegis-management`.
- **Password**: Generate a strong unique password and store it in a password manager. This password will be used only during bootstrap and break-glass.
- **Contact information**: Use your real legal address. AWS applies tax treatment based on this address; for EU residents, reverse-charge VAT rules apply automatically.
- **Credit card**: AWS places a small pre-authorization hold for verification.
- **Identity verification**: AWS will ask for phone verification by SMS or automated voice call. Have your phone ready.
- **Support plan**: Select **Basic Support (Free)**. Paid plans are not appropriate for this project; see the support-plan discussion in this repository for the full rationale.

### 2.3 Capture the account ID

After signup completes, the AWS console displays the 12-digit account ID. Save it. It will be used in `config/landing-zone.yaml` in Phase 1 as the management account's expected account ID for runtime validation.

---

## Part 3: Root User Hardening (Minimum Viable)

Full root hardening (hardware MFA, offline credential storage, break-glass IAM user, SCP restrictions on root API usage) is out of scope per ADR-001 and is handled externally. What this runbook covers is the minimum viable security that every AWS account must have: root MFA via a virtual authenticator.

### 3.1 Enable MFA

1. In the AWS console, click the account name in the top-right corner and select **Security credentials**.
2. Under **Multi-factor authentication (MFA)**, click **Assign MFA device**.
3. Name the device descriptively, for example `aegis-primary-virtual-mfa`.
4. Select **Authenticator app** as the MFA type.
5. Scan the QR code with your authenticator app.
6. Enter two consecutive TOTP codes from the app when prompted; AWS uses these to verify clock synchronization.
7. Click **Add MFA**.

### 3.2 Verify MFA by logging out and back in

This step is critical. A misconfigured MFA setup will not require a code on the next login, and you will discover this only at the worst possible moment. Log out of the root user. Log back in using the root email and password. AWS should prompt for the MFA code. If it does not, the MFA is not correctly bound to the account; retry the setup.

### 3.3 Optional but recommended: add a second MFA device

AWS Organizations allows up to eight MFA devices per root user since 2024. A single-device configuration means that losing the phone effectively locks you out of the account. Repeat Part 3.1 with a second device — a second phone, a tablet, or a password manager capable of TOTP generation (1Password works natively). Store the second device's recovery material separately from the first.

### 3.4 Cold-store the root user

After this point, the root user is never used for routine operations. All further work happens through AWS IAM Identity Center. Do not create access keys for the root user under any circumstances.

---

## Part 3.5: Pre-Control-Tower Cost Guardrails

Before launching AWS Control Tower, set up cost protection. Control Tower begins billing its persistent baseline (AWS Config recorder, CloudTrail, S3 log storage) immediately after enrollment completes. Without budget alerts in place, a misconfiguration in a later phase could silently accumulate cost for weeks before you notice.

### 3.5.1 The "Free Plan" to "Paid Plan" transition email (expected, not a problem)

Shortly after completing Part 2 signup, you may receive an email from AWS stating that your account has been automatically upgraded from a free plan to a paid plan. This email is NOT about your Support Plan — you selected Basic Support (Free) in Part 2, and that remains unchanged. The email refers to the AWS Free Plan promotional status that new accounts start with. The transition to Paid Plan means your account is now in normal billing state and will incur charges for AWS services you use beyond free-tier allowances.

This email is expected, not a problem. It does not signify that AWS has begun recurring billing — it simply moves the account out of the initial promotional window. Do not click any link in the email; verify it came from a legitimate AWS domain and move on. If this email appears unexpectedly and you did not just complete Part 2 signup, treat it as a potential phishing attempt.

### 3.5.2 Create a monthly budget alarm

1. Navigate to **AWS Billing and Cost Management > Budgets**.
2. Click **Create budget > Use a template (simplified)**.
3. Select **Monthly cost budget**.
4. Fill in:
   - **Budget name**: `aegis-monthly-usd30`
   - **Budgeted amount**: `30` USD
   - **Email recipients**: `aws-aegis-management@your-domain.org` plus your personal email (e.g. Gmail) as a redundancy channel. Budget alert notifications are free regardless of recipient count. Adding a second email ensures you receive cost warnings even if your domain's email routing has an outage.
5. Create.

The $30 cap covers the approximately $5/month persistent Control Tower baseline plus per-session ephemeral workload costs plus headroom for spikes, sized against the cost model in ADR-009.

### 3.5.3 Create a daily budget alarm

A daily alarm is a faster circuit breaker than the monthly one.

1. Back at **Budgets**, click **Create budget > Customize (advanced)**.
2. Select **Cost budget** with **Period: Daily**.
3. Fill in:
   - **Budget name**: `aegis-daily-usd10`
   - **Budgeted amount**: `10` USD per day
4. Add an alert threshold at **80% of actual**, emailed to `aws-aegis-management@your-domain.org`.

The $10/day ceiling matches the project-wide daily guardrail in CLAUDE.md. A day exceeding this threshold indicates a runaway resource and should trigger immediate investigation.

### 3.5.4 Enable Cost Explorer

1. Navigate to **AWS Billing and Cost Management > Cost Explorer**.
2. Click **Enable Cost Explorer**.

Cost Explorer takes approximately 24 hours to populate initial data after enablement, so enable it now even though it is not immediately useful. It is the primary tool for verifying weekly that actual cost matches the model in ADR-009.

---

## Part 4: AWS Control Tower Enrollment

Control Tower provisions the managed landing zone foundation. It creates the Audit and Log Archive accounts automatically (mapped to `aegis-security` and `aegis-logarchive` in this project), installs baseline guardrails, enables organizational CloudTrail and AWS Config, and bootstraps IAM Identity Center. See ADR-008 for the tooling rationale.

This part is the longest and most error-prone step in the runbook. **Read through the entire section once before clicking anything.** The wizard has four steps and several fields that default to values you must override; launching with defaults in place will produce a landing zone that violates ADR-002 (region strategy) and ADR-006 (OU structure).

### 4.1 Before starting

Verify the following are complete:

- Part 1 through Part 3 of this runbook.
- Part 3.5: monthly and daily budget alarms exist, Cost Explorer enabled.
- You are logged in as the root user of the management account.
- The console top-right region selector shows **Europe (Frankfurt) — eu-central-1**.
- You have at least 90 minutes available (30 minutes for the wizard, 30-60 minutes for Control Tower provisioning to run).

Navigate to **AWS Control Tower** in the console and click **Set up landing zone**.

### 4.2 Step 1 — Choose setup preferences

**Setup preference**: Select **I want to set up a full environment**.

**Home Region**: Select **Europe (Frankfurt) — eu-central-1**.

> **Permanent decision.** Once Control Tower launches, the home region cannot be changed without fully decommissioning the landing zone, which is subject to AWS account-closure constraints described in ADR-009 (90-day lockout, 10% / 30-day rolling quota). If the wizard defaults to a different region such as `us-east-1`, change it manually before proceeding.

**Region deny setting**: **Enable**.

> **Most commonly missed setting.** Region deny is a preventive guardrail (Service Control Policy) that denies API calls in regions other than the home region plus governed additional regions. The wizard defaults to "Not enabled", meaning workloads could be deployed to any region and bypass ADR-002. Toggle Region deny on explicitly. The guardrail automatically excludes AWS global services such as IAM, Route 53, and Organizations, so enabling it at setup is safe.

**Additional Regions**: Add **Europe (Ireland) — eu-west-1** as the DR region per ADR-002. Do not add any other regions.

### 4.3 Step 2 — Create organizational units (OUs)

**Foundational OU**: Accept the default name **Security**. This OU contains the Audit and Log Archive accounts and is aligned with ADR-006.

**Additional OU**: The wizard defaults this field to **Sandbox**. **Do not accept this default.**

Per ADR-006, the simplified SRA OU structure for this project uses `Security`, `Infrastructure`, and `Workloads` — not `Sandbox`. Rename the additional OU to **Infrastructure**. This OU will later host the `aegis-shared` account (provisioned via AFT in Phase 1 Part B) containing the Terraform state bucket and shared services.

If the wizard allows multiple additional OUs, add a second one named **Workloads** for future `aegis-staging` and `aegis-prod` accounts. If only one additional OU is allowed at setup, create `Infrastructure` only; `Workloads` can be registered after launch via **AWS Control Tower > Organizational units > Register OU**.

Do **not** create an OU named `Sandbox` under any circumstances, even if the wizard offers it by default. Sandbox workloads are out of scope per ADR-001 and ADR-006.

### 4.4 Step 3 — Configure Service integrations

This step configures Config, CloudTrail, Identity Center, and AWS Backup.

**Default OU for service integrations**: Select **Security**. Config and CloudTrail deploy into accounts within this OU.

#### 4.4.1 AWS Config

- **Selected configuration**: Enabled (keep default)
- **Log configuration for Amazon S3**: 1.00 year (365 days) — keep default
- **AWS account access configuration**: 10.00 years (3650 days) — keep default
- **KMS encryption for Config**: If the wizard offers a dedicated Config KMS option, enable it and reuse the CloudTrail KMS key (see 4.4.3). If the wizard does not offer a Config-specific KMS field, accept that Config will be encrypted with an AWS-owned key; this is a known partial implementation of ISO 27001 Annex A.8.24 and is recorded as such in the compliance mapping document.

> **Known Control Tower 3.x gotcha:** In some versions, the wizard configures KMS encryption for CloudTrail but does not offer a matching field for Config. The final review screen will show `Key ARN: -` for Config while CloudTrail has a key. This is non-blocking; the data is still encrypted at rest via AWS-managed encryption. A follow-up Terraform task in Phase 1 Part B can add a customer-managed key for Config if desired.

#### 4.4.2 AWS CloudTrail Centralized logging

- **Selected configuration**: Enabled (keep default)
- **Amazon S3 bucket retention for logging**: 1.00 year — keep default
- **Amazon S3 bucket retention for access logging**: 10.00 years — keep default
- **KMS encryption**: **Enable** and select **Create new key**. The wizard opens a KMS key creation dialog described in 4.4.3.

#### 4.4.3 KMS key creation dialog

When you select **Create new key** for CloudTrail KMS encryption, the wizard opens a KMS key creation form. Fill it as follows:

**Alias**: `alias/aegis-control-tower-key`

> **Required field with no default.** If left blank, the wizard rejects submission with "A key alias is required." Do not use any alias starting with `alias/aws/`; that prefix is reserved for AWS-managed keys and will be rejected.

**Description** (paste verbatim):

> Customer-managed KMS key used by AWS Control Tower to encrypt CloudTrail organization trail logs, AWS Config snapshots, and landing zone metadata in the Log Archive account. Created during initial landing zone enrollment (runbook 001 Part 4). Key policy is managed by the Control Tower service — do not modify the policy manually. ISO 27001 Annex A.8.24 (cryptography) implementation.

**Key settings** — accept every default:

- Key type: Symmetric
- Key spec: SYMMETRIC_DEFAULT
- Key usage: Encrypt and decrypt
- Key material origin: AWS_KMS
- Automatic key rotation: Enabled (annual, free)
- Multi-Region key: Not enabled
- Key policy: do not edit. The wizard attaches the correct policy automatically; manual edits will cause the Control Tower launch to fail.

**Tags** — project tagging taxonomy:

```
Project=aegis-landing-zone-lab
Environment=management
ManagedBy=control-tower
CostCenter=lab
Owner=<your identifier, e.g. bin.hsu>
DataClassification=confidential
Compliance=iso27001
```

Note that `ManagedBy=control-tower`, not `terraform` — this key is created and managed by the Control Tower service, not by Terraform, and the tag must reflect that reality.

If the wizard imposes a lower tag-count limit, the minimum viable tag set is `Project`, `Environment`, and `ManagedBy`. The remaining four can be added later via the KMS console or Terraform.

Click **Create key**. The wizard returns to Control Tower Step 3 with the CloudTrail Key ARN populated.

> **CRITICAL: The wizard-generated default key policy is INSUFFICIENT.** Before clicking Enable on the Control Tower review screen, you must open a second browser tab and update this key's policy to grant the `cloudtrail.amazonaws.com` and `config.amazonaws.com` service principals permission to use the key, plus cross-account decrypt permission for the `aegis-logarchive` and `aegis-security` accounts. Skipping this step causes the `AWSControlTowerBP-BASELINE-CLOUDTRAIL-MASTER` StackSet deployment to fail during enrollment, leading to the recovery sequence in section 4.11 Recovery 6. This failure mode is the single most common Control Tower first-launch issue in a fresh account.

**Policy update procedure (do this before returning to Step 4 Review)**:

1. Open a new browser tab and navigate to **KMS > Customer managed keys**.
2. Click **alias/aegis-control-tower-key**.
3. Click the **Key policy** tab.
4. If the view shows a "Default view" editor, click **Switch to policy view**.
5. Click **Edit**.
6. Select all existing JSON and replace with the following v2 policy template. Substitute the three placeholders with your actual account IDs before saving:

```json
{
  "Version": "2012-10-17",
  "Id": "aegis-control-tower-key-policy-v2",
  "Statement": [
    {
      "Sid": "EnableIAMUserPermissions",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<MANAGEMENT_ACCOUNT_ID>:root"
      },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowCloudTrailToEncryptLogs",
      "Effect": "Allow",
      "Principal": {
        "Service": "cloudtrail.amazonaws.com"
      },
      "Action": "kms:GenerateDataKey*",
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "kms:EncryptionContext:aws:cloudtrail:arn": [
            "arn:aws:cloudtrail:*:<MANAGEMENT_ACCOUNT_ID>:trail/*"
          ]
        }
      }
    },
    {
      "Sid": "AllowCloudTrailToDescribeKey",
      "Effect": "Allow",
      "Principal": {
        "Service": "cloudtrail.amazonaws.com"
      },
      "Action": "kms:DescribeKey",
      "Resource": "*"
    },
    {
      "Sid": "AllowAWSConfigToEncryptAndDecrypt",
      "Effect": "Allow",
      "Principal": {
        "Service": "config.amazonaws.com"
      },
      "Action": [
        "kms:Decrypt",
        "kms:GenerateDataKey"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowAWSConfigToDescribeKey",
      "Effect": "Allow",
      "Principal": {
        "Service": "config.amazonaws.com"
      },
      "Action": "kms:DescribeKey",
      "Resource": "*"
    },
    {
      "Sid": "AllowManagementAccountPrincipalsToDecryptCloudTrailLogs",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<MANAGEMENT_ACCOUNT_ID>:root"
      },
      "Action": [
        "kms:Decrypt",
        "kms:ReEncryptFrom"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:CallerAccount": "<MANAGEMENT_ACCOUNT_ID>"
        },
        "StringLike": {
          "kms:EncryptionContext:aws:cloudtrail:arn": "arn:aws:cloudtrail:*:<MANAGEMENT_ACCOUNT_ID>:trail/*"
        }
      }
    },
    {
      "Sid": "AllowLogArchiveAccountToReadEncryptedLogs",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<LOG_ARCHIVE_ACCOUNT_ID>:root"
      },
      "Action": [
        "kms:Decrypt",
        "kms:DescribeKey"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowSecurityAccountToReadEncryptedLogs",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<SECURITY_ACCOUNT_ID>:root"
      },
      "Action": [
        "kms:Decrypt",
        "kms:DescribeKey"
      ],
      "Resource": "*"
    }
  ]
}
```

Placeholder substitutions:
- `<MANAGEMENT_ACCOUNT_ID>`: the twelve-digit account ID of the management account (captured in Part 2). Appears four times in the policy.
- `<LOG_ARCHIVE_ACCOUNT_ID>`: the twelve-digit account ID of the Log Archive account, which Control Tower creates earlier in the wizard and displays on the review screen.
- `<SECURITY_ACCOUNT_ID>`: the twelve-digit account ID of the Audit/Security account, same source.

7. Click **Save changes**. AWS validates the JSON; if validation fails, check for missing commas, brackets, mistyped account IDs, or accidentally pasted whitespace.
8. Return to the Control Tower Step 4 review tab and continue to section 4.5.

**Why the wizard-generated default is insufficient**: The default key policy that Control Tower's wizard creates authorizes only the management account root user. It does not include service-principal statements for `cloudtrail.amazonaws.com` or `config.amazonaws.com`, and does not include cross-account statements for the logarchive and security accounts that need to read encrypted log objects. The Control Tower baseline StackSet for CloudTrail assumes these statements exist and fails with `Invalid request provided: Insufficient permissions to access S3 bucket ... or KMS key ...` when they are missing. This is a gap in the wizard's behavior, not a bug in your configuration.

#### 4.4.4 AWS IAM Identity Center account access

Keep the default: **Opted in / Enabled**. The sub-option **AWS Control Tower to generate directory groups and permissions sets with IAM Identity Center** should also remain enabled — Control Tower will pre-create a small set of baseline permission sets that are useful as starting references, even though Part 5 creates a custom `PlatformAdmin` permission set.

#### 4.4.5 AWS Backup

Leave at the default: **Not enabled**.

AWS Backup is intentionally not enabled in this project until Phase 3 introduces stateful workloads. The landing zone has no stateful data through Phase 2 and minimal stateful data until Phase 3 EKS workloads exist. Enabling AWS Backup now would accumulate snapshot storage cost for resources that do not need protection. A future Phase 3 ADR will define the workload backup strategy, including organization-level backup policies for `aegis-prod` stateful resources, cross-region copy to `eu-west-1`, and Backup Vault Lock for immutability aligned with ISO 27001 Annex A.8.13.

### 4.5 Step 4 — Review and enable AWS Control Tower

The review screen summarizes all previous selections. **Before clicking Enable AWS Control Tower, verify every field in this checklist**:

```
Step 1 — Setup preferences:
  [ ] Setup preference: I want to set up a full environment
  [ ] Home Region: Europe (Frankfurt) — eu-central-1          ← PERMANENT
  [ ] Region deny: Enabled                                    ← CRITICAL
  [ ] Additional Regions: Europe (Ireland) — eu-west-1

Step 2 — Organizational units:
  [ ] Foundational OU: Security
  [ ] Additional OU: Infrastructure                           ← NOT Sandbox
  [ ] (Optional) Second additional OU: Workloads

Step 3 — Service integrations:
  [ ] Default OU: Security
  [ ] AWS Config: Enabled, aegis-security account
        S3 log retention: 1 year
        Access config retention: 10 years
        Key ARN: ideally populated, acceptable if blank
  [ ] AWS CloudTrail: Enabled, aegis-logarchive account
        S3 retention: 1 year
        Access retention: 10 years
        Key ARN: arn:aws:kms:eu-central-1:<management-id>:key/<uuid>   ← REQUIRED
  [ ] IAM Identity Center: Opted in / Enabled
  [ ] AWS Backup: Not enabled
```

The review screen also displays the **account IDs of the Audit (aegis-security) and Log Archive (aegis-logarchive) accounts that Control Tower has already created for you**. Record these account IDs before clicking launch — they will be needed in Phase 1 Part B for `config/landing-zone.yaml`.

### 4.6 Common review-screen pitfalls (go back and fix before launching)

If any of the following are true on the review screen, click **Previous** and fix the issue before launching:

- **Region deny shows "Not enabled"** — return to Step 1 and toggle it on.
- **Additional OU shows "Sandbox"** — return to Step 2 and rename to `Infrastructure`.
- **AWS Config Key ARN shows `-`** — return to Step 3 and look for a Config KMS option. If the option does not exist in your wizard version, accept as a known gap (see 4.4.1).
- **Home Region is anything other than `eu-central-1`** — return to Step 1 immediately. This is permanent once launched.
- **AWS Backup is Enabled** — return to Step 3 and disable it.

Some versions of the Control Tower wizard lock earlier steps once you advance. If you find a setting wrong and the wizard will not let you return, click **Cancel**, confirm, and restart the wizard from the top. Cancelling before launch does not leave persistent state; the Audit and Log Archive accounts created during the aborted attempt will persist but can be reused on the next attempt.

### 4.7 Launch

> **Point of no return.** Control Tower provisioning **cannot be interrupted** once the Enable button is clicked. There is no cancel button in the console, no cancel API in the CLI, closing the browser tab has no effect, and AWS Basic Support cannot stop it. You must let the enrollment run to completion (success or failure) before you can take any further action. For this reason, verify the checklist in section 4.5 and 4.6 three times before clicking Enable. If you launch with wrong settings, you will be stuck waiting 30-60 minutes before you can fix anything. See section 4.11 for post-launch recovery procedures.

When the review is clean, click **Enable AWS Control Tower**. Control Tower begins provisioning. The progress page shows each provisioning step.

Do not close the browser tab, but you do not need to interact during provisioning. Expected duration: 30 to 60 minutes. The longest-running steps are typically:

1. Creating StackSets in the management account
2. Deploying baseline StackSets into all three accounts (CloudTrail, Config, SSM baselines)
3. Enabling AWS Config aggregators in the `aegis-security` account
4. Creating the organizational CloudTrail trail in the `aegis-logarchive` account
5. Enabling IAM Identity Center and creating baseline permission sets

Leave the tab open and use the time for other work. Return periodically to check progress.

### 4.8 Verification after success

Control Tower displays a success message when complete. Verify by navigating to each of these:

- **AWS Organizations** — The OU tree shows: Root > Security (containing `aegis-security` and `aegis-logarchive`) > Infrastructure (empty for now, `aegis-shared` will be added in Phase 1 Part B via AFT).
- **AWS Control Tower > Dashboard** — All three accounts (`aegis-management`, `aegis-security`, `aegis-logarchive`) show status "Enrolled".
- **AWS Control Tower > Guardrails** — Baseline guardrails are enabled, including the Region deny preventive guardrail.
- **Cost Explorer** — After approximately 24 hours, it begins showing AWS Config and CloudTrail accrued costs.

### 4.9 Capture state for Phase 1 Part B

The following values are the outputs of Part 4 and will be consumed by Terraform in Phase 1 Part B when `config/landing-zone.yaml` is written. Record them in a secure location now:

```
aegis-management account ID:   (captured in Part 2)
aegis-security account ID:      (shown in Control Tower dashboard)
aegis-logarchive account ID:    (shown in Control Tower dashboard)
KMS key ARN for CloudTrail:     arn:aws:kms:eu-central-1:<management-id>:key/<uuid>
Organization ID:                o-XXXXXXXXXX  (shown in Organizations console)
IAM Identity Center start URL:  https://<instance-id>.awsapps.com/start (saved in Part 5.2)
```

### 4.10 Troubleshooting

- **Provisioning fails with "account email already exists"**: The email address is attached to an existing AWS account. Verify Cloudflare Email Routing's catch-all is working and that no other AWS account is using the `aws-aegis-security@` or `aws-aegis-logarchive@` addresses. If you cancelled a previous Control Tower attempt, the audit and logarchive accounts may already exist; in that case, the wizard should detect and reuse them.
- **Provisioning stuck for over 90 minutes**: Check **CloudTrail > Event history** in the management account for errors. Common root causes include pre-existing CloudTrail trails, pre-existing Config recorders, or region conflicts. This runbook assumes a fresh account (Scenario A) where none of these pre-existing resources are present.
- **Wizard will not let you return to a previous step before launching**: Some wizard versions lock earlier steps once you advance. Click **Cancel**, confirm, and restart the wizard from the top. Cancelling before the final Enable click does not leave persistent state beyond the Audit and Log Archive accounts that may have been pre-created.
- **Audit / Log Archive accounts already created from a prior attempt**: If you cancelled a previous wizard run, the accounts persist. The new wizard run detects and reuses them. Account IDs remain stable across retries.
- **Account names cannot be changed after creation**: Control Tower creates `aegis-security` and `aegis-logarchive` with the names you specified in Step 3. Changing these names later requires renaming in the AWS Billing Console and updating all cross-references. Get the names right the first time.

### 4.11 Post-launch recovery (if you launched with wrong settings)

If you clicked Enable without fixing review-screen issues, **you cannot interrupt** — Control Tower must finish provisioning before recovery is possible. The good news is that most misconfigurations are recoverable post-launch via **Modify landing zone** or via direct AWS Organizations actions. The only truly permanent decision is the home region.

Wait for Control Tower enrollment to complete (success state), then apply the recovery procedure for each issue:

**Recovery 1 — Region deny guardrail was not enabled at setup:**

1. Navigate to **AWS Control Tower > Landing zone settings**.
2. Click **Modify landing zone**.
3. In the Region settings section, set **Region deny setting** to **Enabled**.
4. Save and launch the update. Control Tower redeploys the baseline SCPs across all accounts. Duration: approximately 20-30 minutes.

**Recovery 2 — Additional OU was accepted as "Sandbox" instead of "Infrastructure":**

Recommended approach: create a new `Infrastructure` OU and delete `Sandbox` (if it still exists and is empty). Do not rename in place; Control Tower's metadata tracks OUs by original name and rename operations risk inconsistency.

1. Navigate to **AWS Control Tower > Organization**.
2. Click **Create resources > Organizational unit** (the exact button location varies by Control Tower version).
3. Create a new OU named `Infrastructure` directly under Root.
4. Optionally repeat for `Workloads` if not already created.
5. If a `Sandbox` OU exists as an unregistered artifact from an earlier failed attempt, delete it via **AWS Organizations** console (not Control Tower, since Control Tower cannot delete OUs it does not manage). Open AWS Organizations, find the `Sandbox` OU under Root, confirm it is empty, and use **Actions > Delete**. If the delete fails due to attached policies, detach them first; if it fails due to reasons you cannot resolve, leaving an empty Sandbox OU has zero functional or cost impact and is acceptable.

**Known display artifact: empty OUs show "Config baseline status: Not enabled"**

After creating new OUs (Infrastructure, Workloads), the Control Tower dashboard will show their `AWS Config baseline status` as `Not enabled` even though `AWS Control Tower baseline status` is `Enabled`. This is **not a bug and requires no fix**. The two baselines operate at different levels:

- **AWS Control Tower baseline** applies at the OU level immediately on registration (governance metadata, preventive SCPs, drift detection). An empty OU can have this baseline `Enabled`.
- **AWS Config baseline** applies at the member-account level via StackSet instances. An empty OU has no member accounts to deploy the Config recorder to, so the StackSet has zero instances and Control Tower's dashboard displays `Not enabled` to reflect "no active deployment".

The Config baseline activates automatically when the first account is provisioned into the OU (via AFT in Phase 1 Part B). At that moment, Control Tower deploys the Config recorder StackSet instance to the new account, and the dashboard status transitions from `Not enabled` to `Enabled` without any manual action. Running `Modify landing zone` on empty OUs will not change this status — the baseline is lazy-activated on account arrival, not on landing zone update.

For reference, the three possible Config baseline status values have distinct meanings:

| Status | Meaning |
|---|---|
| `Not applicable` | Foundational OU (Security) with configuration managed directly by the landing zone itself, not via the OU baseline mechanism |
| `Not enabled` | Registered OU with zero member accounts; baseline is lazy-pending and will activate on first account arrival |
| `Enabled` | Registered OU with at least one member account where the Config recorder StackSet instance has deployed successfully |

**Recovery 3 — AWS Config Key ARN is blank on the review screen after launch:**

Some Control Tower 3.x wizard versions do not expose a Config-specific KMS option, so this is often a wizard limitation rather than a user error. Recovery options:

1. First try **Modify landing zone** and look for a Config KMS field — if it now appears, populate it with the CloudTrail KMS key ARN and run the update.
2. If Modify landing zone does not offer the option, accept this as a known partial implementation of ISO 27001 Annex A.8.24 and document it in `docs/compliance/iso27001-mapping.md` when that file is created in Phase 1 Part B. The Config data is still encrypted at rest with an AWS-managed key — not optimal but not broken.
3. Alternatively, in Phase 1 Part B, use Terraform to directly configure the AWS Config recorder's KMS key. This requires importing the existing recorder into Terraform state, which adds complexity but gives full control.

**Recovery 4 — Home Region is wrong (the only unrecoverable scenario):**

If the home region was accidentally launched as anything other than `eu-central-1`, the landing zone cannot be corrected without full decommissioning. Decommissioning incurs the 90-day account closure lockout described in ADR-009, plus a full re-enrollment of Control Tower from scratch. This is the worst-case scenario and the reason section 4.7 emphasizes triple-checking the home region before launching. If this happens to you, see ADR-009 for the account closure constraints and plan for a 90-day delay before rebuilding.

**Recovery 5 — Wrong account name for audit or log archive:**

Control Tower creates `aegis-security` and `aegis-logarchive` with the names provided during setup. Post-launch name changes require renaming in AWS Billing Console. This is cosmetic for Terraform purposes (Terraform uses account IDs, not names) but affects visual consistency. Low priority; fix opportunistically.

**Recovery 6 — CloudTrail baseline StackSet failed with KMS permission error:**

This is the most common Control Tower first-launch failure in a fresh account and is caused by an insufficient KMS key policy as described in section 4.4.3. The recovery is a multi-phase operation because CloudFormation state must be cleaned up before Control Tower's retry mechanism can succeed.

**Symptom**: Control Tower provisioning fails. Clicking into the failed enrollment shows an error pointing to the stack `AWSControlTowerBP-BASELINE-CLOUDTRAIL-MASTER`. Navigating to CloudFormation and opening the stack's Events tab shows a CREATE_FAILED event with a status reason similar to:

```
Resource handler returned message: "Invalid request provided:
Insufficient permissions to access S3 bucket aws-controltower-cloudtrail-logs-<logarchive>-xxx
or KMS key arn:aws:kms:eu-central-1:<management>:key/<uuid>.
(Service: CloudTrail, Status Code: 400, ...)"
```

The error message's "S3 bucket OR KMS key" wording is misleading. The S3 bucket is created by Control Tower with a correct bucket policy; the KMS key is the actual culprit in nearly every case.

**Phase A — Fix the KMS key policy**

If you reached this recovery section because you skipped the proactive policy update in section 4.4.3, apply the v2 policy now. Navigate to **KMS > Customer managed keys > alias/aegis-control-tower-key > Key policy > Edit** and paste the v2 JSON template from section 4.4.3, substituting the three account ID placeholders with your real IDs. Save.

**Phase B — Delete the failed CloudFormation stack**

Control Tower's retry mechanism cannot update a stack that is in `ROLLBACK_COMPLETE`, `CREATE_FAILED`, or `ROLLBACK_FAILED` state. CloudFormation refuses to update stacks in these states; they must be deleted first.

1. Navigate to **CloudFormation > Stacks** in region `eu-central-1`.
2. Find `AWSControlTowerBP-BASELINE-CLOUDTRAIL-MASTER`.
3. Check the stack's current state via the stack detail page:
   - `ROLLBACK_COMPLETE` or `CREATE_FAILED`: safe to delete. Proceed to step 4.
   - `ROLLBACK_FAILED`: a resource failed to delete during the initial rollback, typically `TrailLogGroup`. Deletion will fail on the same resource. Proceed to step 4 and expect to need Phase C.
4. Click **Actions > Delete stack > Delete**.
5. If the delete succeeds, skip to Phase D.
6. If the delete fails with an error of the form `The following resource(s) failed to delete: [TrailLogGroup]`, continue to Phase C.

**Phase C — Manually delete the blocking CloudWatch log group**

The `TrailLogGroup` is a CloudWatch Logs log group that CloudFormation cannot delete for reasons outside its control. Manual deletion unblocks the stack deletion.

1. In a new browser tab, navigate to **CloudWatch > Log groups** in region `eu-central-1`.
2. In the search box, try `control`, `trail`, or `cloudtrail` until you find the log group created by the failed stack. Typical names include `aws-controltower/CloudTrailLogs` or similar patterns.
3. Click into the log group. If it has **Subscription filters** or **Metric filters**, delete those first — either of them can block the parent log group's deletion.
4. Return to the log group list, select the log group, click **Actions > Delete log group**, and confirm.
5. Verify the log group is gone from the list.
6. Return to the CloudFormation tab.
7. Retry **Actions > Delete stack > Delete** on `AWSControlTowerBP-BASELINE-CLOUDTRAIL-MASTER`. This time deletion should succeed because the blocking log group is gone.
8. If deletion still fails on the same resource, the log group was re-created in the meantime (rare) or the deletion is blocked by some other dependency. As a last resort, use CloudFormation's delete dialog option to **Retain resources** and select `TrailLogGroup` to skip; the stack will delete but the log group remains orphaned, which is a cosmetic issue only.

**Phase D — Clean up any other failed stacks**

A cascade failure is possible: when the CloudTrail baseline fails, dependent stacks may also fail. In CloudFormation, filter for stacks named `AWSControlTowerBP-*` and examine the state of each. Delete any that are in `CREATE_FAILED`, `ROLLBACK_COMPLETE`, or `ROLLBACK_FAILED` state, repeating Phase C's manual cleanup procedure if any of them have stuck resources. Do not delete stacks in `CREATE_COMPLETE` or `UPDATE_COMPLETE` state — those are working and Control Tower will reuse them on retry.

**Phase E — Retry Control Tower enrollment**

1. Return to **AWS Control Tower > Dashboard**.
2. Click **Retry setup** or equivalent.
3. The wizard walks through the four configuration steps again. Note that **Step 2 (Organizational units) is not editable on retry** — Control Tower tracks OU state and will not allow renaming in place. If the previous attempt created an OU named `Sandbox` from the wizard's default, it will persist and reappear on the retry wizard. This is not a blocker; handle it via Recovery 2 after the landing zone is active.
4. On the review screen, verify every field matches the checklist in section 4.5. Critically, verify:
   - `Region deny: Enabled`
   - `Additional Regions: eu-west-1`
   - `AWS CloudTrail Key ARN: arn:aws:kms:eu-central-1:<management>:key/<uuid>`
   - `AWS Config Key ARN: arn:aws:kms:eu-central-1:<management>:key/<uuid>` (same key as CloudTrail)
5. Click **Enable AWS Control Tower**.
6. With the KMS policy now correct and the stale stacks cleaned, the enrollment should complete successfully in 30-60 minutes.

**Lessons from this recovery:**

1. The wizard-generated default KMS key policy is the root cause of this entire recovery chain. Section 4.4.3 now contains a prominent warning to update the policy before launching. Applying that fix proactively skips this entire recovery section.
2. CloudFormation stacks in `ROLLBACK_FAILED` state cannot be updated, only deleted. Control Tower's retry alone is insufficient; manual CloudFormation cleanup is required.
3. CloudWatch log groups can block CloudFormation stack deletion if they have subscription filters, metric filters, or other attached constructs. The recovery involves manual intervention at the CloudWatch level.
4. The fact that Phase 0 initial bootstrap includes this recovery path demonstrates why the AWS Control Tower + Terraform Hybrid choice from ADR-008 is load-bearing: if this project had hand-rolled Organizations, this entire failure mode would not exist, but neither would the forty minutes of Control Tower baseline setup that hand-rolling would otherwise require. The net trade-off still favors Control Tower; this recovery section is the "insurance premium" paid for the speed of the managed service.

**General principle**: Control Tower's **Modify landing zone** action is the primary recovery mechanism for most post-launch issues. Use it liberally for anything that can be expressed as a landing zone configuration change. Use Terraform post-launch for anything Modify landing zone cannot reach. For failures that predate successful enrollment (as in Recovery 6), the recovery involves CloudFormation cleanup rather than Modify landing zone.

---

## Part 5: IAM Identity Center User Setup

IAM Identity Center was enabled automatically by Control Tower. This part creates your own user, a permission set, and assigns the permission set to the management account.

### 5.1 Open Identity Center

Navigate to **IAM Identity Center** in the AWS console (while still logged in as root).

### 5.2 Note the start URL

On the Identity Center dashboard, find and save the **AWS access portal URL**, which looks like `https://<instance-id>.awsapps.com/start`. This URL is the future login entry point and is needed for `aws configure sso` in Part 6.

### 5.3 Create a user

Navigate to **Users > Add user**. Fill in:

- **Username**: `bin` (or a short lowercase identifier)
- **Email**: Your real personal email (NOT an `aws-aegis-*@your-domain.org` alias). Identity Center sends a welcome email that you need to act on; a real mailbox is clearer here than a catch-all.
- **First name / Last name**: Your real name.

Leave other fields at default. Click **Add user**.

### 5.4 Create a permission set

Navigate to **Multi-account permissions > Permission sets > Create permission set**.

- Select **Predefined permission set**.
- Choose **AdministratorAccess** (this is Tier 2 RBAC starting point per prior planning; ABAC refinement is a future evolution).
- Name the set `PlatformAdmin`.
- Set session duration to **8 hours** (the default, which is appropriate for interactive work).
- Click **Create**.

### 5.5 Assign the permission set to your user

Navigate to **AWS accounts** in the Identity Center console. Select the `aegis-management` account (account ID `186052668286` if this is the project's original instance). Click **Assign users or groups**. Select your user. Click **Next**. Select the `PlatformAdmin` permission set. Click **Next** and **Submit**.

### 5.6 Accept the welcome email

Check the email address you entered in Part 5.3. Identity Center sent a welcome email with a link to set your initial password and enable user-level MFA. Complete both steps. This MFA is independent of the root MFA in Part 3 and protects your daily-use identity.

### 5.6.1 First login verification (do this before cold-storing root)

After completing Parts 5.4 (permission set) and 5.5 (assignment), verify that the SSO login works end to end before cold-storing the root user. Open an **incognito / private browser window** (to avoid cookie conflicts with the root session) and navigate to the AWS access portal URL saved in Part 5.2.

> **The login field accepts your username, not your email.** Enter the short username you created in Part 5.3 (for example, `bin`), not the email address associated with the user. This is different from the AWS root user login flow, which uses email. If the login is rejected, verify you are typing the username.

> **Do not attempt to log in before completing Parts 5.4 and 5.5.** The Identity Center user is an identity only. Without a permission set assigned to a specific account, the portal will display no AWS accounts after login. This is not a login failure — it is the expected result of a user with no account assignments. Complete the permission set creation and assignment first, then verify login.

After logging in, the portal should display the account you assigned in Part 5.5 (for example, `aegis-management`) with the permission set name (for example, `PlatformAdmin`) as an available role. Click **Management Console** to enter the AWS console as the SSO user. Verify the top-right corner shows the SSO role, not the root user.

If the portal shows no accounts, return to the root user session and verify Part 5.5 completed successfully. If the login is rejected entirely, verify the username, reset the password via "Forgot password" on the portal login page, and ensure MFA is correctly configured.

### 5.7 Cold-store the root user again

Log out of the root user. From this point forward, you never log in as root unless for break-glass scenarios.

---

## Part 6: Local SSO Configuration

This part configures your local machine so that AWS CLI, Terraform, and any AWS SDK can authenticate via Identity Center without ever touching `~/.aws/credentials`.

### 6.1 Verify CLI version

Run `aws --version`. You need version 2.15 or later for the modern `sso-session` configuration format. If your version is older, upgrade before continuing.

### 6.2 Run the SSO configure wizard

```
aws configure sso
```

The wizard prompts for:

- **SSO session name**: `aegis`
- **SSO start URL**: the URL you saved in Part 5.2.
- **SSO region**: `eu-central-1`
- **SSO registration scopes**: accept the default `sso:account:access`.

The wizard opens a browser and asks you to confirm the device. Approve. The wizard then lists the accounts and roles available to you; select `aegis-management` and `PlatformAdmin`. It offers a profile name; use `aegis-management-admin`.

### 6.3 Verify the profile

Your `~/.aws/config` should now contain entries similar to:

```
[sso-session aegis]
sso_start_url = https://<instance-id>.awsapps.com/start
sso_region = eu-central-1
sso_registration_scopes = sso:account:access

[profile aegis-management-admin]
sso_session = aegis
sso_account_id = 186052668286
sso_role_name = PlatformAdmin
region = eu-central-1
output = json
```

Your `~/.aws/credentials` file should not exist, or should contain no `aegis-*` entries.

### 6.4 Test authentication

```
aws sso login --sso-session aegis
```

A browser opens and prompts you to confirm; approve. The CLI caches short-lived credentials in `~/.aws/sso/cache/`.

Verify identity:

```
export AWS_PROFILE=aegis-management-admin
aws sts get-caller-identity
```

The output should show the management account ID and a role ARN containing `AWSReservedSSO_PlatformAdmin_*`.

---

## Part 7: Terraform Handoff

You are now ready to run Terraform against the management account. Terraform's AWS provider reads the same `~/.aws/config` and uses the SSO session automatically.

### 7.1 Daily usage pattern

At the start of each working session:

```
aws sso login --sso-session aegis
export AWS_PROFILE=aegis-management-admin
```

All subsequent `terraform`, `aws`, or `kubectl` commands (when EKS is in place) use the SSO session. The session lasts 8 hours by default. When it expires, simply re-run `aws sso login`.

### 7.2 Switching accounts

Once additional accounts exist (after AFT provisioning in Phase 1), switching is a matter of changing the profile:

```
export AWS_PROFILE=aegis-staging-admin
aws sts get-caller-identity
```

No new login is required; the same SSO session covers all profiles that reference it.

### 7.3 No long-lived credentials on disk

At no point in this flow have you written an IAM access key to `~/.aws/credentials`. Verify:

```
cat ~/.aws/credentials
```

This file should not exist or should be empty of `aegis-*` content. If it does contain access keys, review how they got there and delete them; the project explicitly forbids long-lived human credentials per ADR-001.

---

## Troubleshooting

- **`aws sso login` opens browser but "device already authorized" error**: Clear `~/.aws/sso/cache/` and retry. Occasionally stale cache files interfere.
- **Terraform says "no valid credential sources"**: Confirm `AWS_PROFILE` is exported in the current shell. Confirm `aws sts get-caller-identity` works in the same shell before running Terraform.
- **SSO session expires mid-`terraform apply`**: Run `aws sso login` in another terminal and then rerun the apply. Terraform will re-read the refreshed credentials.
- **Control Tower enrollment fails after 90 minutes**: Check `AWS CloudTrail > Event history` for errors. Common causes include pre-existing CloudTrail trails with overlapping names, or pre-existing Config recorders. This runbook assumes a fresh account (Scenario A) where none of these pre-existing resources are present.

## Cross-References

- ADR-001: Landing Zone Scope Boundary — the "SSO only for humans" principle.
- ADR-002: Region and Availability Zone Strategy — the `eu-central-1` home region decision.
- ADR-004: Deployment Configuration Contract — how account IDs collected in this runbook are consumed by Terraform.
- ADR-006: Account Taxonomy and OU Structure — the target account layout after AFT provisioning in Phase 1.
- ADR-008: Landing Zone Tooling — the Control Tower + Terraform Hybrid decision that makes Part 4 the correct path.
- ADR-009: Lifecycle and Teardown Strategy — what to do with all of this when the project reaches end of life.

## Part 8: Create aegis-shared Account (Account Factory — Manual)

This is the **only** account created manually via console. All subsequent accounts (aegis-staging, aegis-prod) are provisioned via Account Factory for Terraform (AFT) after the state bucket exists. See ADR-010 for the rationale: this manual step breaks the chicken-and-egg cycle between AFT (which needs a state bucket) and the shared account (which hosts the state bucket).

### 8.1 Prerequisites — Service Catalog Portfolio Access

> **CRITICAL GOTCHA**: Control Tower's Account Factory is a Service Catalog product. By default, Control Tower only grants portfolio access to its own built-in permission sets (`AWSAdministratorAccess` and `AWSServiceCatalogEndUserAccess`). If you created a custom permission set (e.g., `PlatformAdmin` per Part 5), it does **not** automatically have access to the Account Factory portfolio. Without this access, you will see: _"No launch paths found for resource: prod-xxxxxxxxx"_.
>
> **Fix before proceeding:**
>
> 1. Find your portfolio ID and SSO role ARN:
>    ```
>    aws servicecatalog list-portfolios --region eu-central-1 \
>      --query 'PortfolioDetails[?starts_with(DisplayName,`AWS Control Tower`)].Id' --output text
>    ```
> 2. Associate your custom permission set role with the portfolio:
>    ```
>    aws servicecatalog associate-principal-with-portfolio \
>      --portfolio-id <portfolio-id> \
>      --principal-arn "arn:aws:iam::<management-account-id>:role/aws-reserved/sso.amazonaws.com/<region>/AWSReservedSSO_<YourPermissionSetName>_<suffix>" \
>      --principal-type IAM \
>      --region eu-central-1
>    ```
> 3. Verify:
>    ```
>    aws servicecatalog list-principals-for-portfolio \
>      --portfolio-id <portfolio-id> --region eu-central-1 \
>      --query 'Principals[].PrincipalARN' --output table
>    ```
>
> Your custom role should now appear alongside the Control Tower defaults.

### 8.1.1 Prerequisites — Clear Landing Zone Drift (if applicable)

If Control Tower's **Create account** page shows _"potential drift in your landing zone"_, this may be caused by residual failed operations from initial Control Tower setup (e.g., the KMS key policy issue in Part 4). Even if the landing zone is currently `ACTIVE` and `IN_SYNC`, the failed operation history can trigger this block.

**Fix:**

1. Navigate to **Control Tower** → **Landing zone settings** → **Modify settings**.
2. Do not change any values. Walk through the wizard and click **Update landing zone** at the end.
3. Wait approximately 20-30 minutes for the re-baseline to complete.
4. **Important**: The Control Tower UI does not auto-refresh after the update completes. You must navigate back to the previous page and reload the browser before retrying. If you stay on the same page, the stale drift error will persist even though the drift has been cleared.
5. Retry **Create account** after refreshing.

**Fallback — Service Catalog direct method**: If the CT UI still blocks after re-baseline and refresh, go to **Service Catalog** → **Products** → **AWS Control Tower Account Factory** → **Launch product**. Fill in the same field values from 8.3. This bypasses the CT UI drift check while still applying all CT baseline guardrails — the underlying provisioning product is identical.

### 8.2 Navigate to Account Factory

1. Sign in to the management account via SSO (`https://d-xxxxxxxxxxxx.awsapps.com/start` → aegis-management).
2. Navigate to **AWS Control Tower** → **Organization** → **Create account**.

> **IMPORTANT**: Use the Control Tower Account Factory, not the raw AWS Organizations "Add an AWS account" page. Account Factory applies the full Control Tower baseline (guardrails, Config recorder, CloudTrail integration, SCP inheritance). Raw Organizations API skips all of this and creates reconciliation debt.

### 8.3 Fill in account details

| Field | Value | Notes |
|-------|-------|-------|
| **Account email** | `aws-aegis-shared@your-domain.org` | Must be a real deliverable address. Uses the email pattern from `config/landing-zone.yaml`. |
| **Display name** | `aegis-shared` | Matches the account naming convention in ADR-006. |
| **SSO user email** | Your personal email (e.g., `pcpunkhades@gmail.com`) | Same Identity Center user; do NOT use the account root email here. |
| **SSO first name / last name** | Your name | Same as Identity Center user created in Part 5. |
| **Organizational unit** | `Infrastructure` | Per ADR-006 OU structure. |

### 8.4 Review and create

Review all fields. Click **Create account**. Account Factory provisions the account through a Service Catalog product, which takes approximately 20-30 minutes.

Monitor progress: **AWS Control Tower** → **Organization** → look for the new account row. Status transitions: `Enrolling` → `Enrolled`.

> **Do not close the browser or navigate away during provisioning.** The Service Catalog product runs a CloudFormation StackSet that creates baseline resources in the new account. Interrupting it leaves the account in an inconsistent state.

### 8.5 Record the account ID

Once the account shows `Enrolled`:

1. Click on the account name → note the **Account ID** (12 digits).
2. Open `config/landing-zone.yaml` and fill in `accounts.shared.id` with the new account ID.
3. Verify the account appears in the correct OU:

```
aws organizations list-accounts-for-parent \
  --parent-id <infrastructure-ou-id> \
  --query 'Accounts[].{Name:Name,Id:Id,Status:Status}' \
  --output table
```

### 8.6 Assign PlatformAdmin permission set to the new account

> **GOTCHA**: Account Factory only provisions Control Tower's built-in permission sets (`AWSAdministratorAccess`, `AWSPowerUserAccess`, `AWSReadOnlyAccess`, `AWSOrganizationsFullAccess`) to the new account. Your custom `PlatformAdmin` permission set is **not** automatically assigned. Without this step, `aws sts get-caller-identity` with the `PlatformAdmin` profile will return `ForbiddenException: No access`.

Assign PlatformAdmin to the new account:

```
aws sso-admin create-account-assignment \
  --instance-arn "arn:aws:sso:::instance/<your-sso-instance-id>" \
  --target-id <new-account-id> \
  --target-type AWS_ACCOUNT \
  --permission-set-arn "<your-PlatformAdmin-permission-set-arn>" \
  --principal-type USER \
  --principal-id "<your-identity-center-user-id>" \
  --region eu-central-1
```

To find the required values:

- **SSO instance ARN**: `aws sso-admin list-instances --region eu-central-1`
- **Permission set ARN**: `aws sso-admin list-permission-sets --instance-arn <instance-arn> --region eu-central-1` then `describe-permission-set` to find `PlatformAdmin`
- **User ID**: `aws identitystore list-users --identity-store-id <identity-store-id> --region eu-central-1 --query 'Users[?UserName==\`bin\`].UserId'`

Wait for the assignment to complete (typically a few seconds):

```
aws sso-admin describe-account-assignment-creation-status \
  --instance-arn <instance-arn> \
  --account-assignment-creation-request-id <request-id-from-above> \
  --region eu-central-1
```

### 8.7 Add SSO profile for the new account

Append to `~/.aws/config`:

```ini
[profile aegis-shared-admin]
sso_session = aegis
sso_account_id = <new-account-id>
sso_role_name = PlatformAdmin
region = eu-central-1
output = json
```

After adding the profile, refresh the SSO session to pick up the new account assignment:

```
aws sso login --sso-session aegis
```

Then verify access:

```
export AWS_PROFILE=aegis-shared-admin
aws sts get-caller-identity
```

The output should show the new account ID and the `AWSReservedSSO_PlatformAdmin_*` role.

### 8.8 Why this is the only manual account

This step exists because of a bootstrap cycle: the Terraform state bucket lives in aegis-shared, but AFT (which automates account creation) requires the state bucket to already exist. Creating aegis-shared manually breaks the cycle at the minimum viable point. Every account after this — aegis-staging, aegis-prod, and any future accounts — is provisioned via AFT with full automation. See ADR-010 for the complete decision record.

---

## Cross-References

- ADR-001: Landing Zone Scope Boundary — the "SSO only for humans" principle.
- ADR-002: Region and Availability Zone Strategy — the `eu-central-1` home region decision.
- ADR-004: Deployment Configuration Contract — how account IDs collected in this runbook are consumed by Terraform.
- ADR-006: Account Taxonomy and OU Structure — the target account layout after AFT provisioning in Phase 1.
- ADR-008: Landing Zone Tooling — the Control Tower + Terraform Hybrid decision that makes Part 4 the correct path.
- ADR-009: Lifecycle and Teardown Strategy — what to do with all of this when the project reaches end of life.
- ADR-010: Shared Account Bootstrap Sequence — why aegis-shared is the only manually created account.

## What's Next

With this runbook complete, you have:

- A working AWS management account at `aegis-management`.
- Root user hardened with virtual MFA and cold-stored.
- Control Tower landing zone provisioned with Security OU baseline.
- IAM Identity Center with a user and `PlatformAdmin` permission set.
- Local SSO configuration enabling Terraform without long-lived credentials.
- `aegis-shared` account provisioned in the Infrastructure OU.

Next step is deploying `terraform/environments/shared/bootstrap/` to create the Terraform state bucket, then migrating from local state to S3 with native locking per ADR-003.
