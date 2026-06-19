# OIDC AssumeRoleWithWebIdentity — Redacted Sample

> **This is a redacted sample artifact.** Account IDs are masked as
> `XXXXXXXXXXXX`. All static credentials, tokens, and private-key material
> have been removed — this project has none by design. The record structure
> is real; the identifiers are anonymised for the public repo.

**Related ADR**: [ADR-014 — CI OIDC role scope-down](../decisions/014-iam-permission-scope-down.md)
**Related ADR**: [ADR-019 — Budgets are IaC and the OIDC trust fails closed](../decisions/019-budgets-iac-and-oidc-fail-closed.md)
**Related runbook**: [001 — Bootstrap AWS Account](../runbooks/001-bootstrap-aws-account.md)

---

## What this proves

GitHub Actions assumes the `gh-tf-plan` role in each member account through
OIDC federation — no static AWS credentials are stored anywhere. The CloudTrail
record below shows:

1. The caller identity is the OIDC provider (`token.actions.githubusercontent.com`),
   not an IAM user.
2. The subject claim (`sub`) matches the repo + environment filter enforced in the
   trust policy (`repo:BinHsu/aegis-landing-zone-aws:environment:management`).
3. The resulting session is short-lived (1 h TTL) and scoped to the
   `gh-tf-plan-baseline` role.
4. The trust condition fails closed: a workflow from any other repo or a missing
   `infra_repo_id` claim is denied at the STS boundary (ADR-019).

---

## Redacted CloudTrail record

```json
{
  "eventVersion": "1.08",
  "userIdentity": {
    "type": "WebIdentityUser",
    "principalId": "arn:aws:sts::XXXXXXXXXXXX:assumed-role/gh-tf-plan-baseline/GitHubActions",
    "arn": "arn:aws:sts::XXXXXXXXXXXX:assumed-role/gh-tf-plan-baseline/GitHubActions",
    "accountId": "XXXXXXXXXXXX",
    "identityProvider": "token.actions.githubusercontent.com",
    "userName": "repo:BinHsu/aegis-landing-zone-aws:environment:management"
  },
  "eventTime": "2026-05-17T10:42:11Z",
  "eventSource": "sts.amazonaws.com",
  "eventName": "AssumeRoleWithWebIdentity",
  "awsRegion": "eu-central-1",
  "requestParameters": {
    "roleArn": "arn:aws:iam::XXXXXXXXXXXX:role/gh-tf-plan-baseline",
    "roleSessionName": "GitHubActions",
    "durationSeconds": 3600
  },
  "responseElements": {
    "credentials": {
      "accessKeyId": "ASIA[REDACTED]",
      "sessionToken": "[REDACTED]",
      "expiration": "2026-05-17T11:42:11Z"
    },
    "assumedRoleUser": {
      "assumedRoleId": "AROA[REDACTED]:GitHubActions",
      "arn": "arn:aws:sts::XXXXXXXXXXXX:assumed-role/gh-tf-plan-baseline/GitHubActions"
    }
  },
  "requestID": "a1b2c3d4-[REDACTED]",
  "eventID": "e5f6a7b8-[REDACTED]",
  "readOnly": false,
  "eventType": "AwsApiCall",
  "managementEvent": true,
  "recipientAccountId": "XXXXXXXXXXXX"
}
```

---

## Trust policy excerpt (enforces fail-closed — ADR-019)

The OIDC trust condition that produced this record:

```json
{
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": "repo:BinHsu/aegis-landing-zone-aws:environment:management"
    },
    "StringLike": {
      "token.actions.githubusercontent.com:sub": "repo:BinHsu/aegis-landing-zone-aws:*"
    }
  }
}
```

When `github.infra_repo_id` is unset the `StringEquals` on `sub` has no
matching value; STS returns `AccessDenied`. The trust fails closed by
construction — no wildcard fallback exists in the policy (ADR-019).

---

## CI run context

The assume-role call originates from a `terraform plan` step in the
`terraform-plan.yml` workflow running on PR against `main`. The GitHub Actions
runner supplies the OIDC JWT automatically via
`actions/configure-aws-credentials`; no credential material is stored in
GitHub Secrets for this account.

The `gh-tf-plan-baseline` role is read-only (IAM `ReadOnlyAccess` + scoped
S3 permissions for state reads); apply uses a separate `gh-tf-apply-baseline`
role with a narrower write surface (ADR-014).
