# Don't set defaults in this file; set them in terraform.tfvars so all values are in a single location.

variable "alarm_email_addresses" {
  type        = list(string)
  description = "Email addresses subscribed to the CloudWatch alarms SNS topic (cloudwatch-alarms.tf). Each address must confirm the subscription email SNS sends it before notifications are delivered. Ignored when alarm_topic_arn is set — subscribe on the existing topic instead."
}
variable "alarm_topic_arn" {
  type        = string
  description = "ARN of an existing SNS topic for CloudWatch alarms to publish to (cloudwatch-alarms.tf). Set this when the account already runs a notification topic wired to Slack/PagerDuty, so these alarms land where the team already looks. Empty means this module creates its own topic, plus a customer managed KMS key for it, and subscribes alarm_email_addresses."
}
variable "bucket" {
  type        = string
  description = "Recommended naming scheme is $${project}-$${environment}-tf-state-$${region}"
}
variable "cluster_name" {
  type        = string
  description = "Recommended naming scheme is $${project}-$${environment}"
}
variable "org_name" {
  type        = string
  description = "Organization name, used to prefix globally-unique resource names such as S3 buckets."
}
variable "cluster_version" {
  type = string
}
variable "eks_addon_version_aws-ebs-csi-driver" {
  type = string
}
variable "eks_addon_version_aws-efs-csi-driver" {
  type = string
}
variable "eks_addon_version_coredns" {
  type = string
}
variable "eks_addon_version_eks-node-monitoring-agent" {
  type = string
}
variable "eks_addon_version_eks-pod-identity-agent" {
  type = string
}
variable "eks_addon_version_kube-proxy" {
  type = string
}
variable "eks_addon_version_snapshot-controller" {
  type = string
}
variable "eks_addon_version_vpc-cni" {
  type = string
}
variable "enable_image_reflector_controller" {
  type        = bool
  description = "Enables the Flux image-reflector-controller IAM role for ECR read access."
}
variable "enable_route53" {
  type        = bool
  description = "Enables Route53 as the DNS provider, and installs cert-manager and external-dns with AWS IAM OIDC authentication, so we don't have to manage access keys."
}
variable "create_route53_zone" {
  type    = bool
  default = true
}
variable "create_spot_service_linked_role" {
  type        = bool
  description = "Creates the account-level AWSServiceRoleForEC2Spot service-linked role that spot NodePools depend on. Set false if the account already has it (any prior spot use creates it implicitly) or another stack manages it — see cluster/karpenter.tf."
}
variable "cnpg_backup_replication" {
  type        = bool
  description = "Replicates every CNPG database backup bucket to replica_region (cnpg-databases.tf). Off, each bucket carries a VantaNoAlert tag instead; on, region loss is covered and Vanta's backup/replication test passes for real. Dev clusters typically leave this off; prod clusters turn it on."
}
variable "replica_region" {
  type        = string
  description = "Destination region for cross-region S3 replication. Today only the CNPG database backup buckets use it (cnpg-databases.tf, when cnpg_backup_replication is on), but it is deliberately not CNPG-named so future replicated buckets can share it. Pick a region different from region, or the replication protects against nothing. Still required (but unused) when nothing replicates, per this repo's no-defaults variables convention."
}
variable "dlm_snapshot_cnpg_databases" {
  type        = bool
  description = "Whether the DLM policy (dlm.tf) also snapshots CNPG database volumes. false swaps the classic EKS-volumes policy for a DLM default policy that skips volumes tagged dlm-exclude=true — the tag fluxcd-template's gp3-no-dlm StorageClass applies — because barman already backs those databases up (cnpg-databases.tf) and daily EBS snapshots of them would be redundant. See dlm.tf for the scope trade-off."
}
variable "region" {
  type = string
}
variable "tags_git_repo" {
  type        = string
  description = "All AWS resources will have a tag named GitRepo with this value, so we know which repo created our resources."
}
variable "vpc_cidr" {
  type = string
}
variable "zone_name" {
  type = string
}
