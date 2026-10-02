variable "name" {
  description = "Node group and launch template name"
  type        = string
}

variable "subnet_id" {
  description = "The one subnet, and so the one zone, the group runs in"
  type        = string
}

variable "kubernetes_version" {
  type = string
}

variable "ami_release_version" {
  type = string
}

variable "instance_types" {
  type = list(string)
}

variable "cluster" {
  description = "Outputs of module.eks for the cluster the nodes join"
  type = object({
    name                       = string
    endpoint                   = string
    certificate_authority_data = string
    service_cidr               = string
    ip_family                  = string
    node_security_group_id     = string
  })
}

variable "ebs_kms_key_arn" {
  description = "Encrypts the root volume"
  type        = string
}
