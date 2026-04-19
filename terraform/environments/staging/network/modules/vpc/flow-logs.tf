# -----------------------------------------------------------------------------
# VPC Flow Logs — one per VPC, all written to the shared bootstrap bucket
# -----------------------------------------------------------------------------
# Per-region VPCs each get their own flow log. All flow logs publish into
# the single bootstrap-owned S3 bucket (cross-region write from eu-west-1
# to eu-central-1 is supported by the flow logs service — it does not
# require the bucket to be in the same region as the VPC).
#
# The flow log is conditionally created: when flow_logs_bucket_arn is null
# (bootstrap not yet applied, or caller explicitly opts out), the resource
# is skipped. This preserves the "VPC applies cleanly even if bootstrap
# hasn't run yet" property from the pre-refactor flow-logs.tf.
# -----------------------------------------------------------------------------

resource "aws_flow_log" "this" {
  provider = aws.this

  count = var.flow_logs_bucket_arn != null ? 1 : 0

  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination      = var.flow_logs_bucket_arn
  log_destination_type = "s3"

  max_aggregation_interval = 600

  destination_options {
    file_format        = "parquet"
    per_hour_partition = true
  }

  tags = {
    Name = "${var.env_name}-${var.region_key}-vpc-flow-log"
  }
}
