# diff --color=always -w -y -W200 <(curl -sL https://raw.githubusercontent.com/aws-ia/terraform-aws-eks-blueprints/main/patterns/stateful/main.tf) main.tf | less -R

provider "aws" {
  region = local.region

  # All the resources created by the aws provider will get all the local tags.
  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}

# Fixing "Error: creating KMS Key: operation error KMS: CreateKey, https response error StatusCode: 400, RequestID: 0690d6a8-4211-4a06-a2ad-febc524ae3f1, MalformedPolicyDocumentException: Policy contains a statement with one or more invalid principals."
# Basically, KMS keys can't be created by an STS assumed Role. We need to get the ARN for the underlying role or user.
# This data source provides information on the IAM source role of an STS assumed role
# For non-role ARNs, this data source simply passes the ARN through issuer ARN
# This is needed because KMS keys need to be
# Ref https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_session_context
# Ref https://github.com/terraform-aws-modules/terraform-aws-eks/issues/2327#issuecomment-1355581682
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

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
    aws-efs-csi-driver = {
      addon_version            = var.eks_addon_version_aws-efs-csi-driver
      service_account_role_arn = module.efs_csi_driver_irsa.arn
    }
  }

  name                       = local.name
  kubernetes_version         = var.cluster_version
  ip_family                  = "ipv6"
  create_cni_ipv6_iam_policy = true

  # For defense in depth, set this to false. A private endpoint requires a VPN,
  # bastion host, or some other way into the AWS VPC.
  #
  # This one setting was the cause of a fairly major refactor. The "kubernetes"
  # and "helm" providers run from GitHub Actions (outside the cluster), so a
  # private endpoint broke everything that talked to the cluster API —
  # external-dns, cert-manager, the AWS Load Balancer Controller, the
  # ClusterIssuer, and the storage-class tweaks. Those have all been moved into
  # fluxcd-template, where Flux reconciles them from inside the cluster, and
  # only the AWS IAM/IRSA roles remain here. A private endpoint is therefore
  # viable now for anyone with in-VPC access.
  #
  # TODO: This is the reason you can't connect to your cluster. Setup AWS VPN
  # Client. Security is more important than convenience.
  endpoint_public_access = false

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
      for i, az in local.azs : "vpc_${i}" => {
        description = "NFS ingress from VPC private subnets"
        cidr_ipv4   = module.vpc.private_subnets_cidr_blocks[i]
      }
    },
    {
      for i, az in local.azs : "vpc_ipv6_${i}" => {
        description = "NFS ingress from VPC private subnets (IPv6)"
        cidr_ipv6   = module.vpc.private_subnets_ipv6_cidr_blocks[i]
      }
    }
  )
}

# Exported for the Flux `efs` StorageClass (fluxcd-template: apps/storage-classes),
# which needs the EFS filesystem id as its parameters.fileSystemId.
output "efs_id" {
  description = "EFS filesystem id, for the Flux efs StorageClass's fileSystemId parameter."
  value       = module.efs.id
}

module "ebs_kms_key" {
  source  = "terraform-aws-modules/kms/aws"
  version = "4.2.0"

  description = "Customer managed key to encrypt EKS managed node group volumes"

  # Policy
  key_administrators = [data.aws_iam_session_context.current.issuer_arn]
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

module "efs_csi_driver_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.2.1"

  attach_efs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:efs-csi-controller-sa"]
    }
  }
  use_name_prefix = true
}
