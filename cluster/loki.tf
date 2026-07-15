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

  # How long to keep superseded (noncurrent) object versions before expiring
  # them. Applies to both source and replica buckets.
  loki_noncurrent_version_expiration_days = 30
}

resource "aws_s3_bucket" "loki" {
  for_each = local.loki_buckets

  bucket = each.value
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
# (via the AWS SDK) and S3 replication both use TLS, so this only blocks misuse.
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

# Versioning is a hard requirement for S3 replication, on both the source and
# the destination buckets.
resource "aws_s3_bucket_versioning" "loki" {
  for_each = local.loki_buckets

  bucket = aws_s3_bucket.loki[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

# Versioning retains every overwritten/deleted object version indefinitely. Loki
# rewrites and compacts objects routinely, so expire noncurrent versions to
# bound storage cost; the current (live) version is never affected.
resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  for_each = local.loki_buckets

  bucket = aws_s3_bucket.loki[each.key].id

  # Lifecycle rules require versioning to already be configured.
  depends_on = [aws_s3_bucket_versioning.loki]

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = local.loki_noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
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
  version = "6.6.1"

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

################################################################################
# Cross-region replication
#
# Each Loki bucket is replicated to an identically-structured bucket in
# var.replica_region for redundancy against a regional failure. Loki itself only
# ever reads/writes the source buckets (above); the replicas are a passive DR
# copy, so they are not added to the loki IRSA policy.
################################################################################

# Destination buckets live in the replica region. They mirror the source
# buckets' encryption, public-access block, and versioning settings.
resource "aws_s3_bucket" "loki_replica" {
  for_each = local.loki_buckets
  provider = aws.replica

  bucket = "${each.value}-replica"

  # The VantaNoAlert tag deactivates the resource in Vanta (marks it out of
  # scope), with the tag value recorded as the reason. Without it, Vanta's
  # backup/replication test flags these buckets as needing replication of
  # their own, even though they exist only as replication destinations.
  # Note this takes the bucket out of scope for ALL Vanta tests, not just the
  # replication one.
  tags = {
    VantaNoAlert = "Replication destination for ${each.value} - this bucket is the DR copy and does not itself need replication"
  }
}

resource "aws_s3_bucket_public_access_block" "loki_replica" {
  for_each = local.loki_buckets
  provider = aws.replica

  bucket = aws_s3_bucket.loki_replica[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Same HTTPS-only enforcement as the source buckets. S3 replication delivers
# over TLS, so denying insecure transport does not affect it.
data "aws_iam_policy_document" "loki_replica_https_only" {
  for_each = local.loki_buckets

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.loki_replica[each.key].arn,
      "${aws_s3_bucket.loki_replica[each.key].arn}/*",
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

resource "aws_s3_bucket_policy" "loki_replica" {
  for_each = local.loki_buckets
  provider = aws.replica

  bucket = aws_s3_bucket.loki_replica[each.key].id
  policy = data.aws_iam_policy_document.loki_replica_https_only[each.key].json

  # The public-access block's block_public_policy setting evaluates bucket
  # policies as they are applied; create it first so this policy isn't rejected.
  depends_on = [aws_s3_bucket_public_access_block.loki_replica]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki_replica" {
  for_each = local.loki_buckets
  provider = aws.replica

  bucket = aws_s3_bucket.loki_replica[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "loki_replica" {
  for_each = local.loki_buckets
  provider = aws.replica

  bucket = aws_s3_bucket.loki_replica[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

# Same noncurrent-version expiry as the source buckets. Replication writes new
# versions (and delete markers) here too, so the replicas accumulate noncurrent
# versions just as the sources do.
resource "aws_s3_bucket_lifecycle_configuration" "loki_replica" {
  for_each = local.loki_buckets
  provider = aws.replica

  bucket = aws_s3_bucket.loki_replica[each.key].id

  depends_on = [aws_s3_bucket_versioning.loki_replica]

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = local.loki_noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Role assumed by the S3 service to copy objects from the source buckets to the
# replicas.
data "aws_iam_policy_document" "loki_replication_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "loki_replication" {
  name               = "${local.name}-loki-s3-replication"
  assume_role_policy = data.aws_iam_policy_document.loki_replication_assume.json
}

# Source buckets are SSE-S3 (AES256), so no KMS decrypt/encrypt permissions are
# required here. Switching either side to SSE-KMS would also require kms:* grants
# and an encryption_configuration block on the destination below.
data "aws_iam_policy_document" "loki_replication" {
  statement {
    sid = "ReadSourceBuckets"
    actions = [
      "s3:GetReplicationConfiguration",
      "s3:ListBucket",
    ]
    resources = [for b in aws_s3_bucket.loki : b.arn]
  }

  statement {
    sid = "ReadSourceObjects"
    actions = [
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging",
    ]
    resources = [for b in aws_s3_bucket.loki : "${b.arn}/*"]
  }

  statement {
    sid = "WriteReplicaObjects"
    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags",
    ]
    resources = [for b in aws_s3_bucket.loki_replica : "${b.arn}/*"]
  }
}

resource "aws_iam_policy" "loki_replication" {
  name        = "${local.name}-loki-s3-replication"
  description = "Allows S3 to replicate the Loki buckets to the replica region"
  policy      = data.aws_iam_policy_document.loki_replication.json
}

resource "aws_iam_role_policy_attachment" "loki_replication" {
  role       = aws_iam_role.loki_replication.name
  policy_arn = aws_iam_policy.loki_replication.arn
}

resource "aws_s3_bucket_replication_configuration" "loki" {
  for_each = local.loki_buckets

  # Replication can only be configured once versioning is enabled on both ends.
  depends_on = [
    aws_s3_bucket_versioning.loki,
    aws_s3_bucket_versioning.loki_replica,
  ]

  role   = aws_iam_role.loki_replication.arn
  bucket = aws_s3_bucket.loki[each.key].id

  rule {
    id     = "replicate-all"
    status = "Enabled"

    destination {
      bucket        = aws_s3_bucket.loki_replica[each.key].arn
      storage_class = "STANDARD"
    }
  }
}

output "loki_bucket_names" {
  description = "Loki S3 bucket names. Set these as loki.storage.bucketNames.{chunks,ruler} in the loki Helm values in fluxcd-template."
  value       = { for k, b in aws_s3_bucket.loki : k => b.id }
}

output "loki_replica_bucket_names" {
  description = "Cross-region replica Loki S3 bucket names (DR copies in var.replica_region)."
  value       = { for k, b in aws_s3_bucket.loki_replica : k => b.id }
}

output "loki_role_arn" {
  description = "IRSA role ARN for the loki ServiceAccount. Set this as the eks.amazonaws.com/role-arn annotation on the loki ServiceAccount in fluxcd-template."
  value       = module.loki_irsa.arn
}
