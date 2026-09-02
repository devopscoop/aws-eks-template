# Based on https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dlm_lifecycle_policy

data "aws_iam_policy_document" "dlm_trust" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "dlm" {
  name               = "${var.cluster_name}-dlm-lifecycle-role"
  assume_role_policy = data.aws_iam_policy_document.dlm_trust.json
}

data "aws_iam_policy_document" "dlm_permissions" {
  statement {
    effect = "Allow"

    actions = [
      "ec2:CreateSnapshot",
      "ec2:CreateSnapshots",
      "ec2:DeleteSnapshot",
      "ec2:DescribeInstances",
      "ec2:DescribeVolumes",
      "ec2:DescribeSnapshots",
    ]

    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:*::snapshot/*"]
  }
}

resource "aws_iam_role_policy" "dlm" {
  name   = "${var.cluster_name}-dlm-lifecycle-policy"
  role   = aws_iam_role.dlm.id
  policy = data.aws_iam_policy_document.dlm_permissions.json
}

# Two mutually exclusive policies, switched by dlm_snapshot_cnpg_databases
# (terraform.tfvars). The flag exists because CNPG databases are backed up by
# barman to S3 (cnpg-databases.tf + fluxcd-template's apps/goalert), so daily
# EBS snapshots of their volumes are redundant spend — and a crash-consistent
# snapshot of one replica's volume is a restore footgun sitting next to
# barman's point-in-time recovery.
#
# Why a whole second policy instead of an exclusion on the first: classic
# (STANDARD) DLM policies select volumes by target_tags only — the API has no
# exclusion mechanism for them. Exclusions exist only on DLM *default*
# policies, so opting CNPG volumes out means switching policy types. The two
# differ in scope, deliberately spelled out here:
#
#   - true  (classic): snapshots exactly the EKS CSI volumes
#     (ebs.csi.aws.com/cluster=true), daily at 05:22, keep 14.
#   - false (default policy): snapshots EVERY EBS volume in the region except
#     boot volumes and volumes tagged dlm-exclude=true, daily (AWS picks the
#     time), keep 14 days. Broader than the classic policy — in this
#     template's dedicated-account layout the extra coverage is boot volumes
#     (excluded) and nothing else, but a subtree consumer sharing an account
#     with other EC2 workloads inherits snapshots of those volumes too. More
#     backup, not less; still, know it's happening.
#
# The dlm-exclude=true tag comes from fluxcd-template's gp3-dangerous
# StorageClass (tagSpecification_1), which CNPG databases use on EKS. Tags
# apply at provision time only: volumes that existed before a workload moved
# to that class keep getting snapshotted until retro-tagged by hand — the
# safe failure mode. After flipping the flag, the old policy's snapshots stop
# being pruned (DLM only deletes snapshots of a live policy); delete the
# leftover SnapshotCreator=DLM snapshots once the new policy has coverage.

resource "aws_dlm_lifecycle_policy" "eks" {
  count = var.dlm_snapshot_cnpg_databases ? 1 : 0

  description        = "Backup all EKS volumes"
  execution_role_arn = aws_iam_role.dlm.arn

  policy_details {
    resource_types = ["VOLUME"]

    schedule {
      name = var.cluster_name

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["05:22"]
      }

      retain_rule {
        count = 14
      }

      tags_to_add = {
        SnapshotCreator = "DLM"
      }

      copy_tags = true
    }

    # All EKS PersistentVolumes in clusters newer than 1.23 have this tag set
    # to true, so we're using this to select only AWS EKS PVs.
    target_tags = {
      "ebs.csi.aws.com/cluster" = "true"
    }
  }
}

# The flag gained a count; keep existing clusters' policy at its new address
# instead of destroying and recreating it.
moved {
  from = aws_dlm_lifecycle_policy.eks
  to   = aws_dlm_lifecycle_policy.eks[0]
}

resource "aws_dlm_lifecycle_policy" "eks_default" {
  count = var.dlm_snapshot_cnpg_databases ? 0 : 1

  # DLM descriptions only allow [0-9A-Za-z _-], so no "=true" here.
  description        = "Backup all volumes except boot volumes and dlm-exclude tagged volumes"
  execution_role_arn = aws_iam_role.dlm.arn
  default_policy     = "VOLUME"

  policy_details {
    policy_language = "SIMPLIFIED"
    resource_type   = "VOLUME"

    # Daily snapshots kept 14 days — parity with the classic policy above
    # (24h interval, retain count 14). Default policies don't take a
    # time-of-day or tags_to_add; copy_tags keeps the volume tags on the
    # snapshots so they stay attributable.
    create_interval = 1
    retain_interval = 14
    copy_tags       = true

    exclusions {
      exclude_boot_volumes = true
      # One deliberately generic tag rather than per-database PVC/namespace
      # tags: exclude_tags is a map (one value per key), so listing CNPG
      # namespaces here would break at the second database. Anything whose
      # backups live elsewhere can opt out with this tag.
      exclude_tags = {
        dlm-exclude = "true"
      }
    }
  }
}
