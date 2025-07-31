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
  name               = "dlm-lifecycle-role"
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
  name   = "dlm-lifecycle-policy"
  role   = aws_iam_role.dlm.id
  policy = data.aws_iam_policy_document.dlm_permissions.json
}

resource "aws_dlm_lifecycle_policy" "eks" {
  description        = "Backup all EKS volumes"
  execution_role_arn = aws_iam_role.dlm.arn

  policy_details {
    resource_types = ["VOLUME"]

    schedule {
      name = "2 weeks of daily snapshots"

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
