# -----------------------------------------------------------------------------
# Bazel remote cache S3 bucket — per aegis-core #72 / ADR-0014 §δ
# -----------------------------------------------------------------------------
# Ephemeral build cache. Objects expire after 14 days — cache is rebuild-
# able from source, so durability is not a concern. No versioning (cache
# entries are immutable by content hash; overwrites are safe).
#
# Cost: $0.023/GB/month Standard. At typical C++ + Go cache size (~2-5 GB),
# this rounds to < $0.15/month.
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "bazel_cache" {
  bucket = "aegis-staging-bazel-cache-${local.account_id}"

  tags = {
    Name = "staging-bazel-cache"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "bazel_cache" {
  bucket = aws_s3_bucket.bazel_cache.id

  rule {
    id     = "expire-cache-entries"
    status = "Enabled"

    expiration {
      days = 14
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

resource "aws_s3_bucket_server_side_encryption_configuration" "bazel_cache" {
  bucket = aws_s3_bucket.bazel_cache.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "bazel_cache" {
  bucket = aws_s3_bucket.bazel_cache.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
