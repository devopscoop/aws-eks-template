# Don't set defaults in this file; set them in terraform.tfvars so all values are in a single location.

variable "admin_email" {
  description = "This is the e-mail address used by cert-manager's ACME issuer. If you aren't using AWS Route53, this variable is not used. The recommended name is \"hostmaster@yourdomain.com\" per https://www.ietf.org/rfc/rfc2142.txt."
  type        = string
}
variable "cluster_name" {
  type        = string
  description = "Recommended naming scheme is $${project}-$${environment}"
}
variable "cluster_version" {
  type = string
}
variable "eks_addon_version_aws-ebs-csi-driver" {
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
variable "eks_addon_version_vpc-cni" {
  type = string
}
variable "enable_route53" {
  type        = bool
  description = "Enables Route53 as the DNS provider, and installs cert-manager and external-dns with AWS IAM OIDC authentication, so we don't have to manage access keys."
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
