################################################################################
# Harbor registry S3 storage (apps/harbor in fluxcd-template)
#
# Harbor's registry stores image blobs here instead of on a ReadWriteOnce EBS
# volume, which is what lets it run more than one replica across AZs: S3 is
# shared, regional storage, so registry pods hold no state of their own. Pulls
# are redirected to presigned S3 URLs, so the bytes come from S3 rather than
# streaming through the registry pods. Harbor's metadata stays in its CNPG
# database (add `harbor = "harbor-db"` to local.cnpg_databases in
# cnpg-backups.tf for that bucket and role).
#
# Access is granted via IRSA, with one wrinkle: Harbor's registry (built from
# goharbor/distribution v2.8.3, as of Harbor 2.15) has a hardcoded AWS
# credential chain without web identity, so it can't assume this role
# itself (goharbor/harbor#12888). A sidecar in fluxcd-template does the
# AssumeRoleWithWebIdentity and hands the registry temporary keys through a
# shared credentials file. The trust policy below is therefore the usual
# IRSA one: nothing here is specific to the workaround, and nothing changes
# when Harbor moves to a registry that supports IRSA directly.
#
# enable_harbor (terraform.tfvars) gates everything in this file.
################################################################################

locals {
  # With org_name "devopscoop" and cluster_name "project1-dev", this yields
  # "devopscoop-project1-dev-harbor-registry".
  harbor_registry_bucket = "${var.org_name}-${var.cluster_name}-harbor-registry"
}

resource "aws_s3_bucket" "harbor_registry" {
  count = var.enable_harbor ? 1 : 0

  bucket = local.harbor_registry_bucket

  # Not replicated: the blobs are build outputs and copies of upstream
  # images, and S3's eleven nines already outlast the EBS volume this
  # replaces. Versioning (below) covers deletions; region loss means
  # re-pushing. VantaNoAlert takes the bucket out of scope for every Vanta
  # test, not just replication. S3 tag values allow only letters, numbers,
  # spaces and + - = . _ : / @ (no commas), and a bad one fails CreateBucket
  # at apply, never at plan.
  tags = {
    VantaNoAlert = "Harbor container image blobs - rebuildable build artifacts and upstream copies - versioned and does not need cross-region replication"
  }
}

resource "aws_s3_bucket_public_access_block" "harbor_registry" {
  count = var.enable_harbor ? 1 : 0

  bucket = aws_s3_bucket.harbor_registry[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Defense in depth: the registry's S3 driver and the presigned URLs it hands
# out are both HTTPS, so this only blocks misuse.
data "aws_iam_policy_document" "harbor_registry_https_only" {
  count = var.enable_harbor ? 1 : 0

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.harbor_registry[0].arn,
      "${aws_s3_bucket.harbor_registry[0].arn}/*",
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

resource "aws_s3_bucket_policy" "harbor_registry" {
  count = var.enable_harbor ? 1 : 0

  bucket = aws_s3_bucket.harbor_registry[0].id
  policy = data.aws_iam_policy_document.harbor_registry_https_only[0].json

  # block_public_policy evaluates policies as they're applied, so it must exist first.
  depends_on = [aws_s3_bucket_public_access_block.harbor_registry]
}

# No SSE config: S3's default SSE-S3 can't be disabled. Add one only for SSE-KMS.

# Versioned, unlike the template's other buckets: this one holds the only
# copy of the cluster's own images, and Harbor's garbage collection deletes
# blobs it believes unreferenced. A GC run after an accidental tag or project
# deletion, or after restoring the database to an earlier point, can delete
# blobs that are still wanted, and a rebuilt image gets a new digest. The
# noncurrent versions below are the undo window (see the lifecycle rule).
resource "aws_s3_bucket_versioning" "harbor_registry" {
  count = var.enable_harbor ? 1 : 0

  bucket = aws_s3_bucket.harbor_registry[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "harbor_registry" {
  count = var.enable_harbor ? 1 : 0

  bucket = aws_s3_bucket.harbor_registry[0].id

  rule {
    id     = "cleanup"
    status = "Enabled"

    filter {}

    # A push interrupted mid-layer leaves a multipart upload that accrues
    # cost until aborted.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    # 14 days, matching the daily EBS snapshots (dlm.tf) the registry
    # volume had before it moved here: the same window to notice a bad
    # deletion and restore the blobs. The cost is that overwritten and
    # deleted objects stay billable for 14 days. That includes every push's
    # upload copy, because the registry commits a layer by copying it from
    # _uploads/ to its blob path and deleting the original.
    noncurrent_version_expiration {
      noncurrent_days = 14
    }

    expiration {
      expired_object_delete_marker = true
    }
  }
}

# The registry's documented S3 permission set
# (https://distribution.github.io/distribution/storage-drivers/s3/), scoped to
# this bucket. ListBucketMultipartUploads, ListMultipartUploadParts, and
# AbortMultipartUpload are for resumable and failed pushes.
data "aws_iam_policy_document" "harbor_registry_s3" {
  count = var.enable_harbor ? 1 : 0

  statement {
    sid = "ListHarborRegistryBucket"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.harbor_registry[0].arn]
  }

  statement {
    sid = "ReadWriteHarborRegistryObjects"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.harbor_registry[0].arn}/*"]
  }
}

resource "aws_iam_policy" "harbor_registry_s3" {
  count = var.enable_harbor ? 1 : 0

  name        = "${local.name}-harbor-registry-s3"
  description = "Read/write access to the Harbor registry S3 bucket"
  policy      = data.aws_iam_policy_document.harbor_registry_s3[0].json
}

module "harbor_registry_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  count = var.enable_harbor ? 1 : 0

  name            = "harbor-registry"
  use_name_prefix = false

  policies = {
    harbor_registry_s3 = aws_iam_policy.harbor_registry_s3[0].arn
  }

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      # The chart creates no ServiceAccounts, so apps/harbor ships this one
      # and points the registry Deployment at it. Only the registry pod (the
      # registry, registryctl, and the credentials sidecar) runs as it;
      # core, jobservice, and the rest never touch the bucket.
      namespace_service_accounts = ["harbor:harbor-registry"]
    }
  }
}

output "harbor_registry_bucket_name" {
  description = "Harbor registry S3 bucket name. Set this as persistence.imageChartStorage.s3.bucket in apps/harbor/values-eks.yaml in fluxcd-template (replace_placeholders.sh fills it in from org_name and cluster_name)."
  value       = one(aws_s3_bucket.harbor_registry[*].id)
}

output "harbor_registry_role_arn" {
  description = "IRSA role ARN for the harbor-registry ServiceAccount. Set this as the eks.amazonaws.com/role-arn annotation in apps/harbor/serviceaccount-registry.yaml in fluxcd-template (replace_placeholders.sh fills in the account ID)."
  value       = one(module.harbor_registry_irsa[*].arn)
}
