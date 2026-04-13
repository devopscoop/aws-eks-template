# diff --color=always -w -y -W200 <(curl -sL https://raw.githubusercontent.com/aws-ia/terraform-aws-eks-blueprints/main/patterns/stateful/main.tf) main.tf | less -R

provider "aws" {
  region = local.region

  # All the resources created by the aws provider will get all the local tags.
  default_tags {
    tags = local.tags
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  # Do not include local zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name   = var.cluster_name
  region = var.region

  vpc_cidr = var.vpc_cidr
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    GitRepo = var.tags_git_repo
  }

  # Needed by examples/helmfile.tf
  # account_id = data.aws_caller_identity.current.account_id

}

################################################################################
# Cluster
################################################################################

# https://github.com/terraform-aws-modules/terraform-aws-eks/blob/master/examples/eks-managed-node-group/eks-al2023.tf
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.18.0"

  addons = {
    aws-ebs-csi-driver = {
      addon_version            = var.eks_addon_version_aws-ebs-csi-driver
      service_account_role_arn = module.ebs_csi_driver_irsa.arn
    }
    snapshot-controller = {
      addon_version = var.eks_addon_version_snapshot-controller
    }
    coredns = {
      addon_version = var.eks_addon_version_coredns
    }
    eks-pod-identity-agent = {
      addon_version  = var.eks_addon_version_eks-pod-identity-agent
      before_compute = true
    }
    kube-proxy = {
      addon_version = var.eks_addon_version_kube-proxy
    }
    vpc-cni = {
      addon_version  = var.eks_addon_version_vpc-cni
      before_compute = true
    }
  }

  name                       = local.name
  kubernetes_version         = var.cluster_version
  ip_family                  = "ipv6"
  create_cni_ipv6_iam_policy = true
  endpoint_public_access     = true

  # Grant AWS SSO roles appropriate access to the cluster
  access_entries = {

    # AWSReservedSSO_AdministratorAccess = {
    #   principal_arn = tolist(data.aws_iam_roles.administratoraccess.arns)[0]
    #   policy_associations = {
    #     AmazonEKSClusterAdminPolicy = {
    #       policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    #       access_scope = {
    #         type = "cluster"
    #       }
    #     }
    #   }
    # }

    # If there are any ViewOnlyAccess roles, uncomment this:
    # AWSReservedSSO_ViewOnlyAccess = {
    #   principal_arn = tolist(data.aws_iam_roles.viewonly.arns)[0]
    #   policy_associations = {
    #     AmazonEKSClusterAdminPolicy = {
    #       policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
    #       access_scope = {
    #         type = "cluster"
    #       }
    #     }
    #   }
    # }

    # After creating the cluster and github-actions-${var.cluster_name}-helm role, uncomment this block.
    # github-actions = {
    #   principal_arn = "arn:aws:iam::${local.account_id}:role/github-actions-${var.cluster_name}-helm"
    #   policy_associations = {
    #     AmazonEKSClusterAdminPolicy = {
    #       policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    #       access_scope = {
    #         type = "cluster"
    #       }
    #     }
    #   }
    # }

  }

  # Give the Terraform identity admin access to the cluster
  # which will allow resources to be deployed into the cluster
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    blue = {

      # Note: `disk_size`, and `remote_access` can only be set when using the EKS managed node group default launch template
      # This module defaults to providing a custom launch template to allow for custom security groups, tag propagation, etc.
      use_custom_launch_template = false
      disk_size                  = 50

      # Remote access cannot be specified with a launch template
      # remote_access = {
      #   ec2_ssh_key               = module.key_pair.key_pair_name
      #   source_security_group_ids = [aws_security_group.remote_access.id]
      # }

      # instance_types = ["t4g.large"]
      # ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = ["t3a.large"]

      min_size = 3
      max_size = 3
      # This value is ignored after the initial creation
      # https://github.com/bryantbiggs/eks-desired-size-hack
      desired_size = 3
    }

  }
}

################################################################################
# Storage Classes
################################################################################

resource "kubernetes_annotations" "gp2" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  # This is true because the resources was already created by the ebs-csi-driver addon
  force = "true"

  metadata {
    name = "gp2"
  }

  annotations = {
    # Modify annotations to remove gp2 as default storage class still retain the class
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  depends_on = [
    module.eks
  ]
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"

    annotations = {
      # Annotation to set gp3 as default storage class
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"

  parameters = {
    encrypted = true
    fsType    = "ext4"
    type      = "gp3"
  }

  depends_on = [
    module.eks
  ]
}

resource "kubernetes_storage_class_v1" "efs" {
  metadata {
    name = "efs"
  }

  storage_provisioner = "efs.csi.aws.com"
  parameters = {
    provisioningMode = "efs-ap" # Dynamic provisioning
    fileSystemId     = module.efs.id
    directoryPerms   = "700"
  }

  mount_options = [
    "iam"
  ]

  depends_on = [
    module.eks
  ]
}

################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  # IPv6
  enable_ipv6                                    = true
  public_subnet_assign_ipv6_address_on_creation  = true
  private_subnet_assign_ipv6_address_on_creation = true
  create_egress_only_igw                         = true
  public_subnet_ipv6_prefixes                    = [0, 1, 2]
  private_subnet_ipv6_prefixes                   = [3, 4, 5]

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

module "efs" {
  source  = "terraform-aws-modules/efs/aws"
  version = "2.0.0"

  creation_token = local.name
  name           = local.name

  # Mount targets / security group
  mount_targets = {
    for k, v in zipmap(local.azs, module.vpc.private_subnets) : k => { subnet_id = v }
  }
  security_group_description = "${local.name} EFS security group"
  security_group_vpc_id      = module.vpc.vpc_id
  security_group_ingress_rules = merge(
    {
      for i, cidr in module.vpc.private_subnets_cidr_blocks : "vpc_${i}" => {
        description = "NFS ingress from VPC private subnets"
        cidr_ipv4   = cidr
      }
    },
    {
      for i, cidr in module.vpc.private_subnets_ipv6_cidr_blocks : "vpc_ipv6_${i}" => {
        description = "NFS ingress from VPC private subnets (IPv6)"
        cidr_ipv6   = cidr
      }
    }
  )
}

module "ebs_kms_key" {
  source  = "terraform-aws-modules/kms/aws"
  version = "4.2.0"

  description = "Customer managed key to encrypt EKS managed node group volumes"

  # Policy
  key_administrators = [data.aws_caller_identity.current.arn]
  key_service_roles_for_autoscaling = [
    # required for the ASG to manage encrypted volumes for nodes
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling",
    # required for the cluster / persistentvolume-controller to create encrypted PVCs
    module.eks.cluster_iam_role_arn,
  ]

  # Aliases
  aliases = ["eks/${local.name}/ebs"]
}

module "ebs_csi_driver_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.2.1"

  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
  use_name_prefix = true
}
