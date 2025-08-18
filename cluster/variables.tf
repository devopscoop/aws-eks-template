variable "region" {
  type = string
}
variable "zone_name" {
  type = string
}
variable "github_repos" {
  type = list(any)
}
variable "cluster_name" {
  type = string
}
variable "eks_addon_version_aws-ebs-csi-driver" {
  type = string
}
variable "eks_addon_version_coredns" {
  type = string
}
variable "eks_addon_version_kube-proxy" {
  type = string
}
variable "eks_addon_version_vpc-cni" {
  type = string
}
variable "tf_bucket" {
  type = string
}
variable "backend_s3_key" {
  type = string
}
variable "tags_git_repo" {
  type = string
}
variable "admin_email" {
  type = string
}
variable "vpc_cidr" {
  type = string
}
variable "dynamodb_table" {
  type    = string
  default = "terraform-state-lock"
}
variable "cluster_version" {
  type = string
}
