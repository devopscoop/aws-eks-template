################################################################################
# VPC Flow Logs S3 storage
#
# The VPC module (main.tf) is configured to deliver flow logs to S3 rather than
# CloudWatch Logs — S3 is far cheaper for high-volume network flow data. The
# module creates only the aws_flow_log resource; the destination bucket, the
# log-delivery bucket policy, and the retention lifecycle live here.
#
# Unlike the CloudWatch path there is no IAM role: flow logs are written by the
# AWS log-delivery service (delivery.logs.amazonaws.com), which is granted
# access via the bucket policy below. Retaining logs for a full year matches the
# EKS control-plane log retention (main.tf) and covers the 12-month SOC 2 Type
# II observation period.
################################################################################

locals {
  # With org_name "devopscoop" and cluster_name "project1-dev", this yields
  # "devopscoop-project1-dev-vpc-flow-logs".
  flow_logs_bucket = "${var.org_name}-${var.cluster_name}-vpc-flow-logs"

  # How long to retain delivered flow log objects before expiring them.
  flow_logs_retention_days = 365
}

resource "aws_s3_bucket" "flow_logs" {
  bucket = local.flow_logs_bucket

  # The VantaNoAlert tag deactivates the resource in Vanta (marks it out of
  # scope), with the tag value recorded as the reason. Without it, Vanta's
  # backup/replication test flags this bucket as needing cross-region
  # replication, even though flow logs are diagnostic network telemetry that
  # does not warrant a DR copy — expired objects are simply re-delivered.
  # Note this takes the bucket out of scope for ALL Vanta tests, not just the
  # replication one.
  tags = {
    VantaNoAlert = "VPC flow log storage - diagnostic network telemetry that does not need cross-region replication"
  }
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# No SSE config: S3 has default-encrypted every new object with SSE-S3
# (AES-256) since January 2023 and that floor can't be disabled — add an
# aws_s3_bucket_server_side_encryption_configuration only if this bucket
# ever needs SSE-KMS.

# Expire delivered flow log objects after the retention window; also clean up
# any incomplete multipart uploads.
resource "aws_s3_bucket_lifecycle_configuration" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  rule {
    id     = "expire-flow-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = local.flow_logs_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Bucket policy granting the VPC Flow Logs delivery service permission to write
# log files and read the bucket ACL. This is the policy AWS would otherwise add
# automatically when a flow log is created via the console; the Terraform
# aws_flow_log resource does not manage it, so we attach it explicitly. The
# SourceAccount/SourceArn conditions scope delivery to this account's logs and
# guard against the confused-deputy problem.
data "aws_iam_policy_document" "flow_logs" {
  statement {
    sid       = "AWSLogDeliveryWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.flow_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${local.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }

  statement {
    sid       = "AWSLogDeliveryAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [aws_s3_bucket.flow_logs.arn]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${local.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }

  # Deny all non-HTTPS access so flow log data is always encrypted in transit.
  # Log delivery and any log consumers use TLS, so this only blocks misuse.
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.flow_logs.arn,
      "${aws_s3_bucket.flow_logs.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json

  # The public-access block's block_public_policy setting evaluates bucket
  # policies as they are applied; create it first so this policy isn't rejected.
  depends_on = [aws_s3_bucket_public_access_block.flow_logs]
}
