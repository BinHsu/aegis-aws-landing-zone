# -----------------------------------------------------------------------------
# Tier 3 Detective Controls — ADR-031 Item A (SHIPPED)
# -----------------------------------------------------------------------------
# EventBridge rule on failed `AssumeRoleWithWebIdentity` events in the mgmt
# account, fanning to an SNS topic with an email subscription. The detective
# complement to ADR-029 (Tier 1 preventive) and ADR-030 (Tier 2B preventive).
# Mgmt-account scope only at MVP; staging + shared deferred per ADR-031 Item B.
# -----------------------------------------------------------------------------

resource "time_sleep" "wait_for_apply_baseline_policy_propagation" {
  # Cold-apply guard: AWS IAM has eventual consistency on policy updates of
  # ~5-30 seconds. The same `terraform apply` that adds the `events:*` /
  # `sns:*` Sids to `gh-tf-apply-baseline` ALSO creates the EventBridge rule
  # and SNS topic, so without this sleep the assumed-role session cache may
  # still be evaluating the OLD policy when CreateTopic / PutRule fires —
  # AccessDeniedException on first cold-apply. PR #186's first apply hit
  # exactly this race; rerun recovered cleanly because by then the policy had
  # propagated. 30s is empirically sufficient for this account's policy size.
  # `triggers` is intentionally omitted: the sleep fires on first create only,
  # not on subsequent policy edits — once the resources exist, the race is
  # past and re-waiting on every apply would be pure latency tax.
  depends_on      = [aws_iam_role_policy.gh_tf_apply_baseline]
  create_duration = "30s"
}

resource "aws_sns_topic" "security_alerts" {
  # SNS topic for Tier 3 detective alerts. Subscribers receive a notification
  # whenever the failed-OIDC-assumption rule (or any future Item B/C rule)
  # matches an event. KMS-encrypted with the AWS-managed SNS key per ADR-031
  # OQ-3 (no mgmt-account project CMK exists today).
  name              = "aegis-security-alerts"
  kms_master_key_id = "alias/aws/sns"

  tags = local.tags

  depends_on = [time_sleep.wait_for_apply_baseline_policy_propagation]
}

resource "aws_sns_topic_subscription" "security_alerts_email" {
  # Email subscription to the alert topic. Endpoint reuses the budget-alerts
  # mailbox per ADR-031 OQ-2 (one less config field for forkers at MVP).
  # Subscription lands in `Pending Confirmation` state — operator must click
  # the AWS-sent confirmation link before alerts deliver. The apply succeeds
  # regardless.
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = local.config.budget.alert_emails[0]
}

resource "aws_cloudwatch_event_rule" "failed_oidc_assumption" {
  # EventBridge rule on failed `AssumeRoleWithWebIdentity` events. The
  # `errorCode: {exists: true}` filter catches every denial mode (AccessDenied,
  # AccessDeniedException, NotAuthorizedException, MalformedPolicyDocument)
  # without enumerating them. Matches a fork-PR-OIDC trust-policy bypass
  # attempt against any `gh-tf-*` role in the mgmt account.
  name        = "aegis-detective-failed-oidc-assumption"
  description = "Tier 3 detective: alert on failed AssumeRoleWithWebIdentity events (potential OIDC trust policy bypass attempt). ADR-031."

  event_pattern = jsonencode({
    source        = ["aws.sts"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["sts.amazonaws.com"]
      eventName   = ["AssumeRoleWithWebIdentity"]
      errorCode   = [{ exists = true }]
    }
  })

  tags = local.tags

  depends_on = [time_sleep.wait_for_apply_baseline_policy_propagation]
}

resource "aws_cloudwatch_event_target" "failed_oidc_assumption_to_sns" {
  # Fans matched events to the SNS topic. The input transformer reduces the
  # 2KB raw CloudTrail JSON to a single human-readable line for the email
  # body. `principalId` is the federated identity (e.g.,
  # `AROAEXAMPLE:repo:fork-owner/fork-repo:ref:refs/heads/evil`); `sourceIp`
  # is GitHub Actions' egress IP; `errorMessage` carries the trust-policy
  # mismatch reason.
  rule      = aws_cloudwatch_event_rule.failed_oidc_assumption.name
  target_id = "send-to-sns-security-alerts"
  arn       = aws_sns_topic.security_alerts.arn

  input_transformer {
    input_paths = {
      eventTime    = "$.detail.eventTime"
      sourceIp     = "$.detail.sourceIPAddress"
      principalId  = "$.detail.userIdentity.principalId"
      errorMessage = "$.detail.errorMessage"
    }
    input_template = "\"AEGIS DETECTIVE: Failed OIDC assumption at <eventTime> from <sourceIp> by <principalId>. Error: <errorMessage>\""
  }
}

resource "aws_sns_topic_policy" "security_alerts" {
  # Topic policy: only the EventBridge service principal can publish, and
  # only on behalf of the specific rule above. `aws:SourceArn` pins the
  # condition to the rule's ARN so any other EventBridge rule in the account
  # (including future Items B/C, which would need their own statement
  # additions or a parameterized policy refactor) cannot publish here.
  arn = aws_sns_topic.security_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgePublishFromDetectiveRule"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.security_alerts.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_cloudwatch_event_rule.failed_oidc_assumption.arn
          }
        }
      }
    ]
  })
}
