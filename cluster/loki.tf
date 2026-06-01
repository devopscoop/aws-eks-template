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
  # var.cluster_name is "project1-dev", so this yields the requested
  # "devopscoop-project1-dev-" bucket name prefix.
  loki_bucket_prefix = "devopscoop-${local.name}"

  loki_buckets = {
    chunks = "${local.loki_bucket_prefix}-loki-chunks"
    ruler  = "${local.loki_bucket_prefix}-loki-ruler"
  }
}

resource "aws_s3_bucket" "loki" {
  for_each = local.loki_buckets

  bucket = each.value
}

resource "aws_s3_bucket_public_access_block" "loki" {
  for_each = aws_s3_bucket.loki

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  for_each = aws_s3_bucket.loki

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
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
  version = "6.6.0"

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

  depends_on = [module.eks]
}

output "loki_bucket_names" {
  description = "Loki S3 bucket names. Set these as loki.storage.bucketNames.{chunks,ruler} in the loki Helm values in fluxcd-template."
  value       = { for k, b in aws_s3_bucket.loki : k => b.id }
}

output "loki_role_arn" {
  description = "IRSA role ARN for the loki ServiceAccount. Set this as the eks.amazonaws.com/role-arn annotation on the loki ServiceAccount in fluxcd-template."
  value       = module.loki_irsa.arn
}
