# -----------------------------------------------------------------------------
# FIS Stop Condition — CloudWatch alarm
# -----------------------------------------------------------------------------
# FIS experiments can reference a CloudWatch alarm as a stop condition:
# if the alarm enters ALARM state during the experiment, FIS aborts and
# (where supported) reverses the action, restoring the target resources.
#
# Design constraint: the alarm MUST live in the same region as the FIS
# experiment. Cross-region alarms would require CloudWatch Metric Streams
# (~$1/month + Kinesis + additional Terraform). Deferred — see ADR-020
# §"Cross-region stop condition" for the full alternatives analysis.
#
# What the alarm watches: EKS API server FAILED request count on the
# primary cluster. A sustained spike during the experiment indicates
# the cluster's control plane is itself misbehaving (not just nodes
# gone — that doesn't fail API calls). If control plane API calls
# start failing during the experiment, something is wrong beyond our
# intentional failure and aborting is the safe response.
#
# Why not "ALB 5xx on primary": a hard primary outage (which is the POINT
# of this experiment) will drive 5xx through the roof, which would abort
# the experiment prematurely — defeating its purpose. The alarm must watch
# something that is ONLY abnormal when the experiment itself is abnormal,
# not when the experiment is succeeding. Cluster API failure count fits:
# the EKS control plane is NOT affected by stopping worker nodes, so its
# failure count should stay near zero throughout the experiment. A spike
# means something else is going wrong — concurrent incident, IAM trust
# drift, control plane stress unrelated to the drill.
#
# Note on metric availability: AWS/EKS publishes ClusterFailedRequestCount
# when the EKS Cluster endpoint experiences failed API calls. Metric data
# points are only emitted when failures occur, so `treat_missing_data =
# notBreaching` is essential — a quiet cluster emits no data, which is the
# healthy state.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "experiment_abort_signal" {
  alarm_name        = "aegis-staging-fis-abort-eks-api-failures"
  alarm_description = "Abort FIS experiment if primary EKS cluster endpoint starts returning failed API calls — see ADR-020."
  namespace         = "AWS/EKS"
  metric_name       = "ClusterFailedRequestCount"
  statistic         = "Sum"
  dimensions = {
    ClusterName = local.primary_cluster_name
  }

  comparison_operator = "GreaterThanThreshold"
  threshold           = 100 # failed requests in 60s — cluster API is actively failing, not just idle
  evaluation_periods  = 2
  period              = 60
  treat_missing_data  = "notBreaching"

  # No alarm_actions — the alarm state is consumed by FIS directly via
  # stop_condition, no SNS notification needed. In a production drill,
  # this would also fan out to PagerDuty / Slack for human awareness.

  tags = {
    Name = "aegis-staging-fis-abort-eks-api-failures"
  }
}
