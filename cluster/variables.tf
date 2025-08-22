# Don't set defaults in this file; set them in terraform.tfvars so all values are in a single location.

variable "admin_email" {
  description = "This is the e-mail address used by cert-manager's ACME issuer. If you aren't using AWS Route53, this variable is not used. The recommended name is \"hostmaster@yourdomain.com\" per https://www.ietf.org/rfc/rfc2142.txt."
  type        = string
}
variable "backend_s3_key" {
  type        = string
  description = "Sets the path within the remote state S3 bucket."
}
variable "cluster_name" {
  type        = string
  description = "Recommended naming scheme is ${project}-${environment}"
}
variable "cluster_version" { type = string }
variable "dynamodb_table" {
  type        = string
  description = "If you changed dynamodb_table_name in bootstrap/terraform.tfvars, set this to the same value."
}
variable "eks_addon_version_aws-ebs-csi-driver" { type = string }
variable "eks_addon_version_coredns" { type = string }
variable "eks_addon_version_kube-proxy" { type = string }
variable "eks_addon_version_vpc-cni" { type = string }
variable "enable_route53" {
  type        = bool
  description = "Enables Route53 as the DNS provider, and installs cert-manager and external-dns with AWS IAM OIDC authentication, so we don't have to manage access keys."
}
variable "region" { type = string }
variable "tags_git_repo" {
  type        = string
  description = "All AWS resources will have a tag named GitRepo with this value, so we know which repo created our resources."
}
variable "tf_bucket" {
  type        = string
  description = "This is the bucket that we created during the bootstrap phase. That module uses the naming scheme: ${var.account_alias}-${var.bucket_purpose}-${var.region}"
}
variable "vpc_cidr" { type = string }
variable "zone_name" { type = string }
