bucket = "project1-dev-tf-state-us-east-2"

# These should be the same as the ones in bootstrap/terraform.tfvars.
cluster_name = "project1-dev"
org_name     = "devopscoop"
region       = "us-east-2"

cluster_version = "1.35"

# Use the update_eks_addons.sh script in this directory to automatically update all EKS addon versions in this file.
eks_addon_version_aws-ebs-csi-driver        = "v1.63.1-eksbuild.1"
eks_addon_version_aws-efs-csi-driver        = "v3.4.1-eksbuild.1"
eks_addon_version_snapshot-controller       = "v8.6.0-eksbuild.4"
eks_addon_version_coredns                   = "v1.14.3-eksbuild.3"
eks_addon_version_eks-node-monitoring-agent = "v1.7.0-eksbuild.1"
eks_addon_version_eks-pod-identity-agent    = "v1.4.0-eksbuild.1"
eks_addon_version_kube-proxy                = "v1.35.3-eksbuild.18"
eks_addon_version_vpc-cni                   = "v1.23.0-eksbuild.1"

enable_image_reflector_controller = true
enable_route53                    = true
create_route53_zone               = true
# Set false if the account already has AWSServiceRoleForEC2Spot (any prior
# spot use creates it implicitly); see cluster/karpenter.tf.
create_spot_service_linked_role = true

# Cross-region replication for the CNPG database backup buckets
# (cnpg-backups.tf). Dev clusters leave this false — the buckets get a
# VantaNoAlert tag instead; prod clusters set true for region-loss
# protection and to satisfy Vanta's backup/replication test. Safe to flip on
# later: S3 only replicates new objects, but barman's recovery window churns
# the bucket contents, so coverage converges within one retention period.
# The replica region must differ from region.
cnpg_backup_replication = false
replica_region          = "us-east-1"

# Email addresses that receive CloudWatch alarm notifications, e.g. high CPU
# on an EKS node (see cloudwatch-alarms.tf). Each address must confirm the
# subscription email SNS sends it before notifications are delivered.
# Ignored when alarm_topic_arn is set.
alarm_email_addresses = []

# Existing SNS topic for the CloudWatch alarms to publish to. Empty means this
# module creates its own topic (and a customer managed KMS key for it). Point
# it at a topic that already reaches the team — one with a chat or paging
# integration on it — and the alarms go somewhere a human will see.
alarm_topic_arn = ""

tags_git_repo = "github.com/devopscoop/project1-dev"
# AWS VPCs require a primary IPv4 CIDR even when using IPv6. The IPv6 CIDR is Amazon-provided.
vpc_cidr  = "10.0.0.0/16"
zone_name = "project1-dev.devops.coop"
