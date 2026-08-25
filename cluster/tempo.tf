################################################################################
# Tempo (monolithic) S3 storage
#
# The grafana-community/tempo Helm chart persists trace blocks to a single S3
# bucket, which maps to tempo.storage.trace.s3.bucket in the chart's values.
# Only the WAL stays on the pod's PVC.
#
# Access is granted via IRSA: the tempo ServiceAccount assumes the role below,
# which is scoped to just this bucket. Set the role ARN as the
# eks.amazonaws.com/role-arn annotation on the tempo ServiceAccount in
# fluxcd-template (see the tempo_role_arn output).
################################################################################

locals {
  # With org_name "devopscoop" and cluster_name "project1-dev", this yields
  # "devopscoop-project1-dev-tempo-traces".
  tempo_bucket = "${var.org_name}-${var.cluster_name}-tempo-traces"
}

resource "aws_s3_bucket" "tempo" {
  bucket = local.tempo_bucket

  # This bucket holds operational trace data and intentionally has no
  # cross-region replica — traces are short-retention debugging telemetry, not
  # compliance-relevant records. The VantaNoAlert tag deactivates the resource
  # in Vanta (marks it out of scope), with the tag value recorded as the
  # reason. Without it, Vanta's backup/replication test flags this bucket as
  # needing replication. Note this takes the bucket out of scope for ALL Vanta
  # tests, not just the replication one.
  tags = {
    VantaNoAlert = "Tempo operational trace storage - does not need cross-region replication"
  }
}

resource "aws_s3_bucket_public_access_block" "tempo" {
  bucket = aws_s3_bucket.tempo.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Deny all non-HTTPS access so trace data is always encrypted in transit.
# Tempo (via its minio-go S3 client) uses TLS, so this only blocks misuse.
data "aws_iam_policy_document" "tempo_https_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.tempo.arn,
      "${aws_s3_bucket.tempo.arn}/*",
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

resource "aws_s3_bucket_policy" "tempo" {
  bucket = aws_s3_bucket.tempo.id
  policy = data.aws_iam_policy_document.tempo_https_only.json

  # The public-access block's block_public_policy setting evaluates bucket
  # policies as they are applied; create it first so this policy isn't rejected.
  depends_on = [aws_s3_bucket_public_access_block.tempo]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tempo" {
  bucket = aws_s3_bucket.tempo.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Clean up incomplete multipart uploads so partial block writes don't linger
# and accrue storage cost. Tempo manages its own object retention via the
# compactor (tempo.retention -> block_retention in fluxcd-template), so there
# is no object-expiration rule here. (Unlike loki.tf, no delete-marker cleanup
# either: that rule exists for buckets that lived through the template's
# cross-region-replication era with versioning enabled, and tempo buckets
# postdate it.)
resource "aws_s3_bucket_lifecycle_configuration" "tempo" {
  bucket = aws_s3_bucket.tempo.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# IAM policy granting the tempo ServiceAccount read/write access to only its
# own bucket. The tagging actions are in Tempo's documented S3 permission set
# (https://grafana.com/docs/tempo/latest/configuration/hosted-storage/s3/) —
# it tags objects during compaction.
data "aws_iam_policy_document" "tempo_s3" {
  statement {
    sid       = "ListTempoBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tempo.arn]
  }

  statement {
    sid = "ReadWriteTempoObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:GetObjectTagging",
      "s3:PutObjectTagging",
    ]
    resources = ["${aws_s3_bucket.tempo.arn}/*"]
  }
}

resource "aws_iam_policy" "tempo_s3" {
  name        = "${local.name}-tempo-s3"
  description = "Read/write access to the Tempo trace-blocks S3 bucket"
  policy      = data.aws_iam_policy_document.tempo_s3.json
}

module "tempo_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.0"

  name            = "tempo"
  use_name_prefix = false

  policies = {
    tempo_s3 = aws_iam_policy.tempo_s3.arn
  }

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      # namespace:serviceaccount — must match where the tempo chart is deployed
      # in fluxcd-template. The chart's default ServiceAccount name is "tempo".
      namespace_service_accounts = ["tempo:tempo"]
    }
  }
}

output "tempo_bucket_name" {
  description = "Tempo S3 bucket name. Set this as tempo.storage.trace.s3.bucket in the tempo Helm values in fluxcd-template."
  value       = aws_s3_bucket.tempo.id
}

output "tempo_role_arn" {
  description = "IRSA role ARN for the tempo ServiceAccount. Set this as the eks.amazonaws.com/role-arn annotation on the tempo ServiceAccount in fluxcd-template."
  value       = module.tempo_irsa.arn
}
