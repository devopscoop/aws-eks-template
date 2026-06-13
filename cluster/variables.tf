# Don't set defaults in this file; set them in terraform.tfvars so all values are in a single location.

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
