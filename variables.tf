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
