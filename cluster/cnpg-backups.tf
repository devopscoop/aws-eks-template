################################################################################
# CloudNativePG database backup storage
#
# One S3 bucket + IRSA role per CNPG Cluster that archives WAL files and base
# backups through the Barman Cloud Plugin (apps/cnpg-barman-plugin in
# fluxcd-template). Barman owns object retention — each database's
# ObjectStore resource sets a recovery window and deletes obsolete backups
# itself — so there is no object-expiration lifecycle rule here.
#
# Access is granted via IRSA: the CNPG instance pods run as a ServiceAccount
# the operator names after the Cluster, which assumes the matching role
# below. Set the role ARN as the eks.amazonaws.com/role-arn annotation in the
# Cluster's serviceAccountTemplate in fluxcd-template (see the
# cnpg_db_role_arns output).
#
# cnpg_backup_replication = true (terraform.tfvars) additionally replicates
# every backup bucket to a second region, for region-loss protection and to
# satisfy Vanta's backup/replication test. Off, each bucket carries a
# VantaNoAlert tag instead. Replication is deliberately all-or-nothing per cluster, not
# per database: the driver is environment criticality (dev vs prod), so the
# switch lives in tfvars, which is exactly what differs between the
# continuously-deployed repo and the prod fork it syncs to. Turning it on
# later is low-risk: S3 only replicates new objects, but barman's recovery
# window churns the bucket's entire contents, so coverage converges to
# complete within one retention period with no batch-replication job.
################################################################################

locals {
  # Every CNPG Cluster that ships barman backups. Key = the namespace the app
  # deploys to; value = the Cluster name (which is also the instance
  # ServiceAccount name, so IRSA trusts <key>:<value>). Adding a database
  # here stamps out its bucket, IAM policy, and role — and its replica
  # bucket + replication rule when cnpg_backup_replication is on; the fluxcd
  # side (ObjectStore, ScheduledBackup, Cluster plugins block, serviceAccount
  # annotation) is still per-app — copy apps/goalert.
  #
  # The stamped resources are deliberately identical: a backup bucket's
  # hardening and the minimal barman IAM grant should never drift between
  # databases. A database that grows genuinely different needs graduates out
  # of this map into its own file.
  cnpg_databases = {
    goalert = "goalert-db"
  }

  # for_each source for everything that only exists when replication is on.
  replicated_cnpg_databases = var.cnpg_backup_replication ? local.cnpg_databases : {}
}

resource "aws_s3_bucket" "cnpg_db_backups" {
  for_each = local.cnpg_databases

  bucket = "${var.org_name}-${var.cluster_name}-${each.value}-backups"

  # With replication off this protects against PVC loss and operator
  # mistakes, not region loss, and the VantaNoAlert tag deactivates the
  # resource in Vanta (marks it out of scope) so its backup/replication test
  # doesn't flag the bucket — acceptable for a dev cluster. Note the tag
  # takes the bucket out of scope for ALL Vanta tests, not just the
  # replication one. With replication on, the test passes for real and the
  # tag goes away.
  tags = var.cnpg_backup_replication ? {} : {
    VantaNoAlert = "${each.key} database backups - this cluster does not need cross-region replication"
  }
}

resource "aws_s3_bucket_public_access_block" "cnpg_db_backups" {
  for_each = local.cnpg_databases

  bucket = aws_s3_bucket.cnpg_db_backups[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Deny all non-HTTPS access so backup data is always encrypted in transit.
# barman-cloud (via boto3) uses TLS, so this only blocks misuse.
data "aws_iam_policy_document" "cnpg_db_backups_https_only" {
  for_each = local.cnpg_databases

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.cnpg_db_backups[each.key].arn,
      "${aws_s3_bucket.cnpg_db_backups[each.key].arn}/*",
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

resource "aws_s3_bucket_policy" "cnpg_db_backups" {
  for_each = local.cnpg_databases

  bucket = aws_s3_bucket.cnpg_db_backups[each.key].id
  policy = data.aws_iam_policy_document.cnpg_db_backups_https_only[each.key].json

  # The public-access block's block_public_policy setting evaluates bucket
  # policies as they are applied; create it first so this policy isn't rejected.
  depends_on = [aws_s3_bucket_public_access_block.cnpg_db_backups]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cnpg_db_backups" {
  for_each = local.cnpg_databases

  bucket = aws_s3_bucket.cnpg_db_backups[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cnpg_db_backups" {
  for_each = local.cnpg_databases

  bucket = aws_s3_bucket.cnpg_db_backups[each.key].id

  rule {
    id     = "cleanup"
    status = "Enabled"

    filter {}

    # Clean up incomplete multipart uploads (an interrupted base backup
    # leaves them behind) so partial writes don't linger and accrue cost.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    # The two rules below only matter once the bucket has (or has ever had)
    # versioning, which replication requires — S3 versioning is a one-way
    # door (Enabled can only ever go to Suspended), so ship the cleanup
    # unconditionally; both are no-ops on a never-versioned bucket. Without
    # them, barman's constant retention deletions leave delete markers and
    # noncurrent versions behind forever — loki.tf's lifecycle comment
    # documents that exact failure mode degrading S3 list performance.
    #
    # 7 days of noncurrent versions is a deliberate safety net: long enough
    # to notice and recover from a runaway retention bug or accidental
    # deletion, short enough that versioning doesn't silently double storage.
    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    expiration {
      expired_object_delete_marker = true
    }
  }
}

# The action list is CloudNativePG's documented minimal S3 permission set for
# barman-cloud (docs appendix "Object stores", AWS S3 section): tagging is
# used to mark WAL files belonging to a backup, and AbortMultipartUpload to
# clean up after interrupted uploads. Each database's role sees only its own
# bucket.
data "aws_iam_policy_document" "cnpg_db_backups_s3" {
  for_each = local.cnpg_databases

  statement {
    sid       = "ListBackupBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.cnpg_db_backups[each.key].arn]
  }

  statement {
    sid = "ReadWriteBackupObjects"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:PutObject",
      "s3:PutObjectTagging",
    ]
    resources = ["${aws_s3_bucket.cnpg_db_backups[each.key].arn}/*"]
  }
}

resource "aws_iam_policy" "cnpg_db_backups_s3" {
  for_each = local.cnpg_databases

  name        = "${local.name}-${each.value}-backups-s3"
  description = "Read/write access to the ${each.key} database backup S3 bucket"
  policy      = data.aws_iam_policy_document.cnpg_db_backups_s3[each.key].json
}

module "cnpg_db_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.0"

  for_each = local.cnpg_databases

  name            = each.value
  use_name_prefix = false

  policies = {
    backups_s3 = aws_iam_policy.cnpg_db_backups_s3[each.key].arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${each.key}:${each.value}"]
    }
  }
}

################################################################################
# Cross-region replication (cnpg_backup_replication = true)
#
# Everything below only exists with the toggle on. The replica buckets get
# the same hardening as the sources. Barman never touches them — they are
# purely the region-loss copy, restored from by hand if the primary region's
# bucket is gone.
################################################################################

# CRR requires versioning on both sides. Note the one-way door: turning the
# toggle off later leaves versioning on the source bucket Suspended, not
# disabled (S3 offers no way back) — the cleanup lifecycle rules above keep
# that state from accumulating garbage, exactly the lesson loki.tf records.
resource "aws_s3_bucket_versioning" "cnpg_db_backups" {
  for_each = local.replicated_cnpg_databases

  bucket = aws_s3_bucket.cnpg_db_backups[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket" "cnpg_db_backups_replica" {
  for_each = local.replicated_cnpg_databases

  provider = aws.replica

  bucket = "${var.org_name}-${var.cluster_name}-${each.value}-backups-replica"
}

resource "aws_s3_bucket_versioning" "cnpg_db_backups_replica" {
  for_each = local.replicated_cnpg_databases

  provider = aws.replica

  bucket = aws_s3_bucket.cnpg_db_backups_replica[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "cnpg_db_backups_replica" {
  for_each = local.replicated_cnpg_databases

  provider = aws.replica

  bucket = aws_s3_bucket.cnpg_db_backups_replica[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "cnpg_db_backups_replica_https_only" {
  for_each = local.replicated_cnpg_databases

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.cnpg_db_backups_replica[each.key].arn,
      "${aws_s3_bucket.cnpg_db_backups_replica[each.key].arn}/*",
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

resource "aws_s3_bucket_policy" "cnpg_db_backups_replica" {
  for_each = local.replicated_cnpg_databases

  provider = aws.replica

  bucket = aws_s3_bucket.cnpg_db_backups_replica[each.key].id
  policy = data.aws_iam_policy_document.cnpg_db_backups_replica_https_only[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.cnpg_db_backups_replica]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cnpg_db_backups_replica" {
  for_each = local.replicated_cnpg_databases

  provider = aws.replica

  bucket = aws_s3_bucket.cnpg_db_backups_replica[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Delete-marker replication (below) mirrors barman's retention deletions
# here, so the replica needs the same cleanup rules or its noncurrent
# versions grow without bound.
resource "aws_s3_bucket_lifecycle_configuration" "cnpg_db_backups_replica" {
  for_each = local.replicated_cnpg_databases

  provider = aws.replica

  bucket = aws_s3_bucket.cnpg_db_backups_replica[each.key].id

  rule {
    id     = "cleanup"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    expiration {
      expired_object_delete_marker = true
    }
  }
}

data "aws_iam_policy_document" "cnpg_db_backups_replication_assume_role" {
  count = var.cnpg_backup_replication ? 1 : 0

  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

# One role covering every database's replication: unlike the per-database
# IRSA roles (each scoped to its own bucket for a pod to assume), this is
# only assumable by the S3 service itself, so per-database isolation buys
# nothing.
resource "aws_iam_role" "cnpg_db_backups_replication" {
  count = var.cnpg_backup_replication ? 1 : 0

  name               = "${local.name}-cnpg-db-backups-replication"
  assume_role_policy = data.aws_iam_policy_document.cnpg_db_backups_replication_assume_role[0].json
}

data "aws_iam_policy_document" "cnpg_db_backups_replication" {
  count = var.cnpg_backup_replication ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "s3:GetReplicationConfiguration",
      "s3:ListBucket",
    ]
    resources = [for k in keys(local.replicated_cnpg_databases) : aws_s3_bucket.cnpg_db_backups[k].arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging",
    ]
    resources = [for k in keys(local.replicated_cnpg_databases) : "${aws_s3_bucket.cnpg_db_backups[k].arn}/*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags",
    ]
    resources = [for k in keys(local.replicated_cnpg_databases) : "${aws_s3_bucket.cnpg_db_backups_replica[k].arn}/*"]
  }
}

resource "aws_iam_role_policy" "cnpg_db_backups_replication" {
  count = var.cnpg_backup_replication ? 1 : 0

  name   = "${local.name}-cnpg-db-backups-replication"
  role   = aws_iam_role.cnpg_db_backups_replication[0].id
  policy = data.aws_iam_policy_document.cnpg_db_backups_replication[0].json
}

resource "aws_s3_bucket_replication_configuration" "cnpg_db_backups" {
  for_each = local.replicated_cnpg_databases

  bucket = aws_s3_bucket.cnpg_db_backups[each.key].id
  role   = aws_iam_role.cnpg_db_backups_replication[0].arn

  rule {
    id     = "backup-replication"
    status = "Enabled"

    filter {}

    # Mirror barman's retention deletions to the replica; without this the
    # replica keeps every object as current forever and grows without bound.
    # A buggy or malicious mass-delete propagates too, but only as delete
    # markers — the replica's noncurrent versions survive for the lifecycle
    # rule's 7-day window, which is the recovery margin.
    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = aws_s3_bucket.cnpg_db_backups_replica[each.key].arn
      storage_class = "STANDARD"
    }
  }

  depends_on = [
    aws_s3_bucket_versioning.cnpg_db_backups,
    aws_s3_bucket_versioning.cnpg_db_backups_replica,
  ]
}

output "cnpg_db_backup_bucket_names" {
  description = "CNPG database backup S3 bucket names, keyed by app. Set as the ObjectStore destinationPath in apps/<app>/objectstore.yaml in fluxcd-template."
  value       = { for k, b in aws_s3_bucket.cnpg_db_backups : k => b.id }
}

output "cnpg_db_role_arns" {
  description = "IRSA role ARNs for the CNPG instance ServiceAccounts, keyed by app. Set as the eks.amazonaws.com/role-arn annotation in the Cluster serviceAccountTemplate in apps/<app>/db-cluster.yaml in fluxcd-template."
  value       = { for k, m in module.cnpg_db_irsa : k => m.arn }
}
