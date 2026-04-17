# -----------------------------------------------------------------------------
# VPC Flow Logs — Phase 4b
# -----------------------------------------------------------------------------
# Network audit trail: all accepted/rejected traffic logged to S3. Delivers
# to a staging-local bucket for now; migration to a centralized logarchive
# bucket (ADR-006: aegis-logarchive account) is a future improvement.
#
# Cost: negligible at lab traffic volume — Flow Logs publishing to S3 is
# $0.25/GB for the first 10 TB (minimal in a lab). Storage: $0.023/GB/month
# for S3 Standard, transitions to IA after 90 days ($0.0125/GB/month).
# Expected total: < $0.50/month.
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "flow_logs" {
  bucket = "aegis-staging-vpc-flow-logs-${local.account_id}"

  tags = {
    Name = "staging-vpc-flow-logs"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

# -----------------------------------------------------------------------------
# Flow Log — captures all traffic (ACCEPT + REJECT) in the default format.
# max_aggregation_interval = 600 (10 min) balances cost vs. resolution.
# -----------------------------------------------------------------------------

resource "aws_flow_log" "main" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination      = aws_s3_bucket.flow_logs.arn
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
