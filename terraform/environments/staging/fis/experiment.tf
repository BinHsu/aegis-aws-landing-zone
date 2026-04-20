# -----------------------------------------------------------------------------
# FIS Experiment Template — Primary-region EKS node outage
# -----------------------------------------------------------------------------
# Demo experiment: stop all Karpenter-provisioned EC2 instances in the
# primary region for 10 minutes, then auto-start them. Simulates a regional
# worker-capacity loss (not a region blackout — the EKS control plane,
# NAT, ALB, etc. remain alive; this is the "nodes gone" failure mode).
#
# What you can observe during the 10-minute window:
#   - kubectl get nodes → all primary-region nodes → NotReady
#   - kubectl get pods -n aegis → pods → Pending (no capacity)
#   - Prometheus alert NodeNotReady fires (staging/workloads observability
#     layer's PrometheusRule) — visible in Grafana's alert panel
#   - Grafana "Kubernetes / Nodes" dashboard → CPU/memory series drop to 0
#   - If ArgoCD has synced aegis-core to both clusters + Route53 failover
#     is wired, external traffic shifts to slave_1 cluster (Region B)
#
# Recovery: FIS auto-starts the stopped instances after duration elapses.
# Karpenter observes them come back, re-onboards to the node pool, and
# pods reschedule. Full recovery typically completes within 2–3 minutes
# of experiment end.
#
# Safety: the aws_cloudwatch_metric_alarm.experiment_abort_signal stop
# condition aborts the experiment if the cluster enters reconcile-storm
# state, preventing the drill from amplifying an existing incident.
#
# Cost: ~$0 for the experiment itself (FIS pricing is per-experiment-
# action execution, ~$0.0095 per action). The cost of the 10-min outage
# on the cluster is zero (stopped EC2 is not billed). Net cost: < $0.01.
# -----------------------------------------------------------------------------

resource "aws_fis_experiment_template" "primary_eks_node_outage" {
  description = "Stop primary-region Karpenter-provisioned EKS worker nodes for 10 minutes. Simulates a regional worker-capacity loss; observes failover and recovery behavior. ADR-020."
  role_arn    = aws_iam_role.fis.arn

  target {
    name           = "karpenter-nodes-primary"
    resource_type  = "aws:ec2:instance"
    selection_mode = "ALL"

    # Target selector: all EC2 instances carrying the Karpenter NodePool
    # tag. The IAM scope-down policy (iam.tf) denies action on instances
    # WITHOUT this tag, so the tag-filter here is defense-in-depth
    # alignment with the IAM posture.
    resource_tag {
      key   = "karpenter.sh/nodepool"
      value = "aegis-default"
    }

    filter {
      path   = "State.Name"
      values = ["running"]
    }
  }

  action {
    name        = "stop-nodes"
    action_id   = "aws:ec2:stop-instances"
    description = "Stop targeted instances for 10 minutes; FIS auto-starts them at duration end."

    target {
      key   = "Instances"
      value = "karpenter-nodes-primary"
    }

    parameter {
      key   = "startInstancesAfterDuration"
      value = "PT10M"
    }
  }

  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.experiment_abort_signal.arn
  }

  # Experiment options: fail-immediately mode aborts the whole experiment
  # if the single action fails to start. Cleaner failure semantics for a
  # one-action experiment than the default fail-on-any mode.
  experiment_options {
    account_targeting            = "single-account"
    empty_target_resolution_mode = "fail"
  }

  tags = {
    Name = "aegis-staging-primary-eks-node-outage"
  }
}
