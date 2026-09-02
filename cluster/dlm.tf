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

# One DLM *default* policy: snapshot every EBS volume in the region except
# boot volumes and volumes tagged dlm-exclude=true, daily, keep 14 days.
#
# A default policy rather than a classic (STANDARD) one because classic
# policies select by target_tags only — the API has no exclusion mechanism
# for them — and we need opt-out: CNPG databases are backed up by barman to
# S3 (cnpg-backups.tf + fluxcd-template's apps/goalert), so daily EBS
# snapshots of their volumes are redundant spend, and a crash-consistent
# snapshot of one replica's volume is a restore footgun sitting next to
# barman's point-in-time recovery. The dlm-exclude=true tag comes from
# fluxcd-template's gp3-dangerous StorageClass (tagSpecification_1). Tags
# apply at provision time only: volumes that existed before a workload moved
# to that class keep getting snapshotted until retro-tagged by hand — the
# safe failure mode.
#
# Scope note: this covers every non-boot volume in the region, not just EKS
# CSI volumes like the classic policy it replaced. In this template's
# dedicated-account layout that is the same set, but a subtree consumer
# sharing an account with other EC2 workloads inherits snapshots of those
# volumes too — more backup, not less; still, know it's happening.
#
# Migration from the classic policy: the old policy's snapshots stop being
# pruned once it's destroyed (DLM only deletes snapshots of a live policy);
# delete the leftover SnapshotCreator=DLM snapshots once this policy has
# coverage.
resource "aws_dlm_lifecycle_policy" "default" {
  # DLM descriptions only allow [0-9A-Za-z _-], so no "=true" here.
  description        = "Backup all volumes except boot volumes and dlm-exclude tagged volumes"
  execution_role_arn = aws_iam_role.dlm.arn
  default_policy     = "VOLUME"

  policy_details {
    policy_language = "SIMPLIFIED"
    resource_type   = "VOLUME"

    # Daily snapshots kept 14 days — parity with the classic policy this
    # replaced (24h interval, retain count 14). Default policies don't take a
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
