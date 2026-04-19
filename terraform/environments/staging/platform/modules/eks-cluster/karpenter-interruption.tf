# -----------------------------------------------------------------------------
# Karpenter spot interruption handling — SQS + EventBridge, per-cluster
# -----------------------------------------------------------------------------
# Karpenter runs Spot by default (ADR-013 Consequences). Spot reclamation
# triggers a 2-minute warning on EventBridge; Karpenter polls the SQS queue
# below and cordon-drains the about-to-be-reclaimed node.
#
# All resources are cluster-scoped — multiple clusters in the same account
# each get their own queue + rules, distinguished by cluster_name prefix.
# -----------------------------------------------------------------------------

resource "aws_sqs_queue" "karpenter_interruption" {
  provider = aws.this

  name                      = "${var.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = {
    Name = "${var.cluster_name}-karpenter-interruption"
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  provider = aws.this

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

resource "aws_cloudwatch_event_rule" "karpenter_spot_interruption" {
  provider = aws.this

  name        = "${var.cluster_name}-karpenter-spot-interruption"
  description = "Spot interruption warning → Karpenter interruption queue"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_spot_interruption" {
  provider = aws.this

  rule = aws_cloudwatch_event_rule.karpenter_spot_interruption.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_scheduled_change" {
  provider = aws.this

  name        = "${var.cluster_name}-karpenter-scheduled-change"
  description = "AWS Health scheduled change → Karpenter interruption queue"

  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event"]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_scheduled_change" {
  provider = aws.this

  rule = aws_cloudwatch_event_rule.karpenter_scheduled_change.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_instance_state_change" {
  provider = aws.this

  name        = "${var.cluster_name}-karpenter-instance-state-change"
  description = "EC2 instance state change → Karpenter interruption queue"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_instance_state_change" {
  provider = aws.this

  rule = aws_cloudwatch_event_rule.karpenter_instance_state_change.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_rebalance" {
  provider = aws.this

  name        = "${var.cluster_name}-karpenter-rebalance"
  description = "EC2 rebalance recommendation → Karpenter interruption queue"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_rebalance" {
  provider = aws.this

  rule = aws_cloudwatch_event_rule.karpenter_rebalance.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}
