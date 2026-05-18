# -----------------------------------------------------------------------------
# VPC Flow Logs — written to the shared bootstrap bucket
# -----------------------------------------------------------------------------
# The flow log publishes into the single bootstrap-owned S3 bucket. A DR-region
# VPC writing cross-region into the eu-central-1 bucket is supported by the
# flow logs service — it does not require the bucket to be co-located.
#
# The flow log is conditionally created: when flow_logs_bucket_arn is null
# (bootstrap not yet applied, or caller explicitly opts out), the resource
# is skipped. This preserves the "VPC applies cleanly even if bootstrap
# hasn't run yet" property.
# -----------------------------------------------------------------------------

resource "aws_flow_log" "this" {
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
    Name = "${var.env_name}-${var.region}-vpc-flow-log"
  }
}
