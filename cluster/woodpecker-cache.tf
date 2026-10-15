################################################################################
# Woodpecker CI pipeline cache storage
#
# One S3 bucket for the cache steps in Woodpecker pipelines (apps/woodpecker
# in fluxcd-template): dependency and build caches, saved and restored as
# tarballs by an S3 cache plugin, one key per branch under a prefix per repo.
# Everything in it is regenerable by the next pipeline run, so unlike the
# CNPG backup and Tempo buckets this one is never backed up or replicated,
# and it expires its own objects: a cache entry not rewritten for 14 days
# belongs to a branch nobody has pushed to in two weeks.
#
# Access is granted via IRSA: the cache steps run as a ServiceAccount in the
# woodpecker namespace that assumes the role below. Woodpecker step pods run
# as the namespace's default ServiceAccount unless a step names another one
# through backend_options.kubernetes.serviceAccountName, so a pipeline opts
# its cache steps in. The EKS pod identity webhook then injects the web
# identity token into those pods, and any S3 client on the AWS SDK's default
# credential chain picks it up with no keys in the pipeline. Set the role ARN
# as the eks.amazonaws.com/role-arn annotation on that ServiceAccount in
# fluxcd-template (see the woodpecker_cache_role_arn output).
#
# A cache plugin that only takes static keys cannot use the role. The
# woodpecker-ci.org s3-cache plugin documents only access_key_id and
# secret_access_key settings; confirm it reads the SDK chain before relying on
# it, or use one that does (meltwater/drone-cache). The alternative — an IAM
# user's access key held as a Woodpecker secret — is what this repo avoids
# everywhere else, so it is deliberately not provisioned here.
################################################################################

locals {
  # With org_name "devopscoop" and cluster_name "project1-dev", this yields
  # "devopscoop-project1-dev-woodpecker-cache".
  woodpecker_cache_bucket = "${var.org_name}-${var.cluster_name}-woodpecker-cache"
}

resource "aws_s3_bucket" "woodpecker_cache" {
  bucket = local.woodpecker_cache_bucket

  # A cache miss costs one cold build, so the bucket has no cross-region
  # replica. The VantaNoAlert tag deactivates the resource in Vanta (marks it
  # out of scope), with the tag value recorded as the reason; without it,
  # Vanta's backup/replication test flags this bucket as needing replication.
  # Note this takes the bucket out of scope for ALL Vanta tests, not just the
  # replication one.
  tags = {
    VantaNoAlert = "Woodpecker CI build cache - regenerable by the next pipeline run, does not need cross-region replication"
  }
}

resource "aws_s3_bucket_public_access_block" "woodpecker_cache" {
  bucket = aws_s3_bucket.woodpecker_cache.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Deny all non-HTTPS access so cache contents are always encrypted in
# transit. The cache plugins' S3 clients use TLS, so this only blocks misuse.
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

  # The public-access block's block_public_policy setting evaluates bucket
  # policies as they are applied; create it first so this policy isn't rejected.
  depends_on = [aws_s3_bucket_public_access_block.woodpecker_cache]
}

# No SSE config: S3 has default-encrypted every new object with SSE-S3
# (AES-256) since January 2023 and that floor can't be disabled — add an
# aws_s3_bucket_server_side_encryption_configuration only if this bucket
# ever needs SSE-KMS (and then grant the IRSA role the KMS actions too).

# Expire cache entries nobody rewrites. A save step overwrites its key's
# object on every run, which resets the object's age, so an active branch's
# cache never expires; only a branch quiet for 14 days loses its entry, and
# the next push to it starts cold, exactly as a new branch does. Incomplete
# multipart uploads (an interrupted save) are aborted after 7 days, same as
# the other buckets. (No delete-marker cleanup — see cnpg-backups.tf: that
# rule is for buckets that have ever had versioning enabled, and this one
# never has.)
resource "aws_s3_bucket_lifecycle_configuration" "woodpecker_cache" {
  bucket = aws_s3_bucket.woodpecker_cache.id

  rule {
    id     = "expire-stale-caches"
    status = "Enabled"

    filter {}

    expiration {
      days = 14
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# IAM policy granting the cache ServiceAccount read/write access to only its
# own bucket: list (does this key exist?), get and put (restore and save),
# delete (the plugins' clear action), and AbortMultipartUpload (a large save
# that fails mid-upload).
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
      # namespace:serviceaccount — the namespace apps/woodpecker deploys to in
      # fluxcd-template, and a ServiceAccount of this name that app creates
      # for cache steps to run as. Not the agent's ServiceAccount: the agent
      # only brokers pods and never touches the bucket.
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
