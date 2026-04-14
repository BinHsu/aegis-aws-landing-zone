# -----------------------------------------------------------------------------
# Karpenter spot interruption handling — SQS + EventBridge
# -----------------------------------------------------------------------------
# Karpenter provisions Spot instances by default (per ADR-013 Consequences).
# Spot instances can be reclaimed by AWS with 2 minutes of warning. When that
# happens, AWS publishes a SpotInterruption event on the default EventBridge
# bus. Karpenter watches for these events via an SQS queue it polls, and
# proactively cordon-drains the about-to-be-reclaimed node while launching
# a replacement — converting a surprise interruption into a graceful drain.
#
# Without this wiring, Spot reclamation just terminates the instance and
# whatever was scheduled on it disappears. With it, workloads get a clean
# eviction notice and typically migrate before the underlying node dies.
#
# The queue + rule are cluster-scoped: the Karpenter controller IAM policy
# (karpenter-iam.tf) grants `sqs:ReceiveMessage` / `sqs:DeleteMessage` only
# on THIS queue's ARN. Per-cluster isolation, even when multiple clusters
# run in the same account.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# SQS queue — the target for EventBridge rules below
# -----------------------------------------------------------------------------
# The queue name is bounded by SQS's 80-character limit; prefixing with the
# cluster name keeps it unique without hashing.
# -----------------------------------------------------------------------------
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${local.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300 # 5 min — interruption notices are only
  # actionable within the 2-minute warning window; retaining longer is
  # pointless and just widens the DLQ candidate window.
  sqs_managed_sse_enabled = true

  tags = {
    Name = "${local.cluster_name}-karpenter-interruption"
  }
}

# -----------------------------------------------------------------------------
# Queue policy — only the EventBridge rules we define below may send to it
# -----------------------------------------------------------------------------
resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.url

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowEventBridge"
      Effect = "Allow"
      Principal = {
        Service = [
          "events.amazonaws.com",
          "sqs.amazonaws.com",
        ]
      }
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.karpenter_interruption.arn
    }]
  })
}

# -----------------------------------------------------------------------------
# EventBridge rules — four event types route to the same queue
# -----------------------------------------------------------------------------
# 1. Spot interruption warning — AWS will reclaim the instance in ~2 min.
# 2. Scheduled change — AWS-initiated retirement (hardware failure, etc.).
# 3. Instance state change — instance is Terminated / Stopping outside
#    Karpenter's control. Karpenter reconciles its view of nodes.
# 4. Rebalance recommendation — low-severity hint that Spot capacity is
#    under pressure; Karpenter can preemptively move workloads.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "karpenter_spot_interruption" {
  name        = "${local.cluster_name}-karpenter-spot-interruption"
  description = "Spot interruption warning → Karpenter interruption queue"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_spot_interruption" {
  rule = aws_cloudwatch_event_rule.karpenter_spot_interruption.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_scheduled_change" {
  name        = "${local.cluster_name}-karpenter-scheduled-change"
  description = "AWS Health scheduled change → Karpenter interruption queue"

  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event"]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_scheduled_change" {
  rule = aws_cloudwatch_event_rule.karpenter_scheduled_change.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_instance_state_change" {
  name        = "${local.cluster_name}-karpenter-instance-state-change"
  description = "EC2 instance state change → Karpenter interruption queue"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_instance_state_change" {
  rule = aws_cloudwatch_event_rule.karpenter_instance_state_change.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_rebalance" {
  name        = "${local.cluster_name}-karpenter-rebalance"
  description = "EC2 rebalance recommendation → Karpenter interruption queue"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_rebalance" {
  rule = aws_cloudwatch_event_rule.karpenter_rebalance.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}
