# -----------------------------------------------------------------------------
# VPC Flow Logs S3 bucket — persistent across teardown cycles
# -----------------------------------------------------------------------------
# The bucket lives in bootstrap (not network) so that `terraform destroy`
# of the network layer deletes the aws_flow_log resource but preserves
# the accumulated log data. Next session's network apply creates a new
# flow log pointing at the same bucket.
#
# The aws_flow_log resource itself stays in staging/network/flow-logs.tf
# because it references the VPC (which belongs to the network layer).
#
# Cost: $0.023/GB/month Standard, transitions to IA at 90 days, expires
# at 365 days. Expected < $0.50/month at lab traffic volume.
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

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
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
