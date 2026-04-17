# -----------------------------------------------------------------------------
# VPC Flow Logs — Phase 4b
# -----------------------------------------------------------------------------
# Network audit trail: all accepted/rejected traffic logged to S3.
#
# The S3 bucket lives in staging/bootstrap (persistent across teardown).
# Only the aws_flow_log resource is here — it is destroyed with the VPC
# on teardown but the bucket and its data survive.
#
# Cost: $0.25/GB publishing fee (negligible at lab traffic).
# -----------------------------------------------------------------------------

resource "aws_flow_log" "main" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination      = data.terraform_remote_state.staging_bootstrap.outputs.flow_logs_bucket_arn
  log_destination_type = "s3"

  max_aggregation_interval = 600

  destination_options {
    file_format        = "parquet"
    per_hour_partition = true
  }

  tags = {
    Name = "staging-vpc-flow-log"
  }
}
