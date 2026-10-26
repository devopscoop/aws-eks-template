################################################################################
# Woodpecker CI pipeline cache (apps/woodpecker in fluxcd-template). Contents
# are regenerable by the next run, so stale entries expire instead of piling up.
################################################################################

locals {
  woodpecker_cache_bucket = "${var.org_name}-${var.cluster_name}-woodpecker-cache"
}

resource "aws_s3_bucket" "woodpecker_cache" {
  bucket = local.woodpecker_cache_bucket

  # Not replicated: a lost cache costs one cold build. VantaNoAlert takes the
  # bucket out of scope for every Vanta test, not just replication. S3 tag
  # values allow only letters, numbers, spaces and + - = . _ : / @ (no
  # commas), and a bad one fails CreateBucket at apply, never at plan.
  tags = {
    VantaNoAlert = "Woodpecker CI build cache - regenerable by the next pipeline run and does not need cross-region replication"
  }
}

resource "aws_s3_bucket_public_access_block" "woodpecker_cache" {
  bucket = aws_s3_bucket.woodpecker_cache.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Defense in depth: the cache plugins already use TLS, so this only blocks misuse.
data "aws_iam_policy_document" "woodpecker_cache_https_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.woodpecker_cache.arn,
      "${aws_s3_bucket.woodpecker_cache.arn}/*",
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

resource "aws_s3_bucket_policy" "woodpecker_cache" {
  bucket = aws_s3_bucket.woodpecker_cache.id
  policy = data.aws_iam_policy_document.woodpecker_cache_https_only.json

  # block_public_policy evaluates policies as they're applied, so it must exist first.
  depends_on = [aws_s3_bucket_public_access_block.woodpecker_cache]
}

# No SSE config: S3's default SSE-S3 can't be disabled. Add one only for SSE-KMS.

# Save steps rewrite their key every run, so only branches idle for 14 days
# lose their cache. Never versioned, so no delete-marker cleanup (see
# cnpg-backups.tf).
resource "aws_s3_bucket_lifecycle_configuration" "woodpecker_cache" {
  bucket = aws_s3_bucket.woodpecker_cache.id

  rule {
    id     = "expire-stale-caches"
    status = "Enabled"

    filter {}

    expiration {
      days = 14
    }

    # An interrupted save leaves a multipart upload that accrues cost until aborted.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Delete is for the plugins' clear action; AbortMultipartUpload for saves that
# fail mid-upload.
data "aws_iam_policy_document" "woodpecker_cache_s3" {
  statement {
    sid       = "ListCacheBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.woodpecker_cache.arn]
  }

  statement {
    sid = "ReadWriteCacheObjects"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.woodpecker_cache.arn}/*"]
  }
}

resource "aws_iam_policy" "woodpecker_cache_s3" {
  name        = "${local.name}-woodpecker-cache-s3"
  description = "Read/write access to the Woodpecker CI pipeline cache S3 bucket"
  policy      = data.aws_iam_policy_document.woodpecker_cache_s3.json
}

# IRSA rather than an access key in a Woodpecker secret. Only works with a
# cache plugin that reads the AWS SDK credential chain; confirm s3-cache does.
module "woodpecker_cache_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  name            = "woodpecker-cache"
  use_name_prefix = false

  policies = {
    woodpecker_cache_s3 = aws_iam_policy.woodpecker_cache_s3.arn
  }

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      # A dedicated SA that cache steps opt into via backend_options, so other
      # steps and the agent (which only brokers pods) never get the bucket.
      namespace_service_accounts = ["woodpecker:woodpecker-cache"]
    }
  }
}

output "woodpecker_cache_bucket_name" {
  description = "Woodpecker CI pipeline cache S3 bucket name. Set this as the bucket setting of the cache plugin steps in each repo's .woodpecker/*.yaml, or publish it as a Woodpecker organization secret so pipelines read it from there."
  value       = aws_s3_bucket.woodpecker_cache.id
}

output "woodpecker_cache_role_arn" {
  description = "IRSA role ARN for the woodpecker-cache ServiceAccount. Set this as the eks.amazonaws.com/role-arn annotation on that ServiceAccount in apps/woodpecker in fluxcd-template."
  value       = module.woodpecker_cache_irsa.arn
}
