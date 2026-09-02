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

# Snapshot every volume tagged Backup=dlm, daily, keep 14. Opt-in by tag:
# the key asks how a volume is backed up and the value answers, so a volume
# with no Backup tag at all is visibly unaccounted for — auditable with one
# describe-volumes query.
#
# The tag comes from fluxcd-template's StorageClasses (tagSpecification_1):
# the default gp3 class applies Backup=dlm, so everything is covered unless
# it deliberately opts out by using gp3-dangerous, which applies Backup=none
# instead — CNPG databases do, because barman already backs them up to S3
# (cnpg-backups.tf + fluxcd-template's apps/goalert), making daily EBS
# snapshots of their volumes redundant spend, and a crash-consistent
# snapshot of one replica's volume a restore footgun sitting next to
# barman's point-in-time recovery.
#
# Two things the opt-in design asks of operators:
#   - Tags apply at provision time only. Volumes that predate the Backup tag
#     (provisioned before fluxcd-template's gp3 class carried it) fall out of
#     the policy until retro-tagged. This lists the unaccounted-for volumes:
#       aws ec2 describe-volumes \
#         --filters Name=tag:ebs.csi.aws.com/cluster,Values=true \
#         --query 'Volumes[?length(Tags[?Key==`Backup`])==`0`].VolumeId'
#     Tag those Backup=dlm by hand, except volumes whose backups genuinely
#     live elsewhere (CNPG's — tag those Backup=none so they stay accounted
#     for).
#   - Any future EBS StorageClass must carry a Backup tag, or its volumes
#     are silently unprotected. The EKS-created gp2 class has no
#     tagSpecification — it is non-default and deliberately unused; don't
#     put workloads on it.
resource "aws_dlm_lifecycle_policy" "eks" {
  description        = "Backup all volumes tagged Backup dlm"
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

    target_tags = {
      Backup = "dlm"
    }
  }
}
