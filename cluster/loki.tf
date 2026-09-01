################################################################################
# Loki (SingleBinary) S3 storage
#
# The grafana/loki Helm chart in SingleBinary mode persists log chunks and the
# TSDB index to S3, and stores ruler state (recording/alerting rules) in a
# second bucket. These map to loki.storage.bucketNames.chunks and
# loki.storage.bucketNames.ruler in the chart's values. The third bucket the
# chart references (admin) is Loki Enterprise (GEL) only and is intentionally
# omitted here.
#
# Access is granted via IRSA: the loki ServiceAccount assumes the role below,
# which is scoped to just these two buckets. Set the role ARN as the
# eks.amazonaws.com/role-arn annotation on the loki ServiceAccount in
# fluxcd-template (see the loki_role_arn output).
################################################################################

locals {
  # With org_name "devopscoop" and cluster_name "project1-dev", this yields the
  # "devopscoop-project1-dev-" bucket name prefix.
  loki_bucket_prefix = "${var.org_name}-${var.cluster_name}"

  loki_buckets = {
    chunks = "${local.loki_bucket_prefix}-loki-chunks"
    ruler  = "${local.loki_bucket_prefix}-loki-ruler"
  }
}

resource "aws_s3_bucket" "loki" {
  for_each = local.loki_buckets

  bucket = each.value

  # These buckets hold operational log data and intentionally have no
  # cross-region replica — the compliance-relevant logs (VPC flow logs, EKS
  # control-plane logs) are the ones retained long-term, not Loki's. The
  # VantaNoAlert tag deactivates the resource in Vanta (marks it out of scope),
  # with the tag value recorded as the reason. Without it, Vanta's
  # backup/replication test flags these buckets as needing replication. Note
  # this takes the bucket out of scope for ALL Vanta tests, not just the
  # replication one.
  tags = {
    VantaNoAlert = "Loki operational log storage - does not need cross-region replication"
  }
}

resource "aws_s3_bucket_public_access_block" "loki" {
  for_each = local.loki_buckets

  bucket = aws_s3_bucket.loki[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Deny all non-HTTPS access so log data is always encrypted in transit. Loki
# (via the AWS SDK) uses TLS, so this only blocks misuse.
data "aws_iam_policy_document" "loki_https_only" {
  for_each = local.loki_buckets

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.loki[each.key].arn,
      "${aws_s3_bucket.loki[each.key].arn}/*",
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

resource "aws_s3_bucket_policy" "loki" {
  for_each = local.loki_buckets

  bucket = aws_s3_bucket.loki[each.key].id
  policy = data.aws_iam_policy_document.loki_https_only[each.key].json

  # The public-access block's block_public_policy setting evaluates bucket
  # policies as they are applied; create it first so this policy isn't rejected.
  depends_on = [aws_s3_bucket_public_access_block.loki]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  for_each = local.loki_buckets

  bucket = aws_s3_bucket.loki[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Clean up incomplete multipart uploads so partial chunk writes don't linger and
# accrue storage cost. Loki manages its own object retention via compaction, so
# there is no object-expiration rule here.
resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  for_each = local.loki_buckets

  bucket = aws_s3_bucket.loki[each.key].id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    # Deployments that upgraded through this template's cross-region-replication
    # era have versioning permanently Suspended on these buckets (S3 offers no
    # way back to unversioned), so every deletion by Loki's compactor leaves a
    # zero-byte delete marker behind forever; enough of them degrade S3 list
    # performance. This expires markers that have no object versions beneath
    # them. No-op for buckets that never had versioning enabled.
    expiration {
      expired_object_delete_marker = true
    }
  }
}

# IAM policy granting the loki ServiceAccount read/write access to only its
# own buckets.
data "aws_iam_policy_document" "loki_s3" {
  statement {
    sid       = "ListLokiBuckets"
    actions   = ["s3:ListBucket"]
    resources = [for b in aws_s3_bucket.loki : b.arn]
  }

  statement {
    sid = "ReadWriteLokiObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [for b in aws_s3_bucket.loki : "${b.arn}/*"]
  }
}

resource "aws_iam_policy" "loki_s3" {
  name        = "${local.name}-loki-s3"
  description = "Read/write access to the Loki chunks and ruler S3 buckets"
  policy      = data.aws_iam_policy_document.loki_s3.json
}

module "loki_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.1"

  name            = "loki"
  use_name_prefix = false

  policies = {
    loki_s3 = aws_iam_policy.loki_s3.arn
  }

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      # namespace:serviceaccount — must match where the loki chart is deployed
      # in fluxcd-template. The chart's default ServiceAccount name is "loki".
      namespace_service_accounts = ["loki:loki"]
    }
  }
}

output "loki_bucket_names" {
  description = "Loki S3 bucket names. Set these as loki.storage.bucketNames.{chunks,ruler} in the loki Helm values in fluxcd-template."
  value       = { for k, b in aws_s3_bucket.loki : k => b.id }
}

output "loki_role_arn" {
  description = "IRSA role ARN for the loki ServiceAccount. Set this as the eks.amazonaws.com/role-arn annotation on the loki ServiceAccount in fluxcd-template."
  value       = module.loki_irsa.arn
}
