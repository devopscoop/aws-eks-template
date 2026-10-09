# diff --color=always -w -y -W200 <(curl -sL https://raw.githubusercontent.com/aws-ia/terraform-aws-eks-blueprints/main/patterns/stateful/main.tf) main.tf | less -R

provider "aws" {
  region = local.region

  # All the resources created by the aws provider will get all the local tags.
  default_tags {
    tags = local.tags
  }
}

# Second region for cross-region S3 replication (replica_region), used by the
# backup buckets. Provider blocks can't be conditional, so it always exists.
provider "aws" {
  alias  = "replica"
  region = var.replica_region

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}

# KMS key policies can't name an STS assumed-role session, so resolve the
# underlying IAM role (non-role ARNs pass through). See
# https://github.com/terraform-aws-modules/terraform-aws-eks/issues/2327#issuecomment-1355581682
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

  # Zones that get a node group, one each. Separate from local.azs so widening
  # the VPC doesn't add node groups.
  availability_zones = slice(local.azs, 0, 3)

  # Node group generations by number; generation N's groups are ng-<zone>-<N>.
  # Changing instance_types replaces a group, so add a generation, move the
  # workloads, then delete the old one: docs/changing-instance-types.md.
  node_group_generations = {
    1 = { instance_types = ["t3a.large"] }
  }

  # One node group per generation per zone. Each entry carries the index of
  # its zone so the group below can pin itself to that zone's private subnet.
  node_groups = merge([
    for generation, group in local.node_group_generations : {
      for i, az in local.availability_zones : "ng-${trimprefix(az, local.region)}-${generation}" => merge(group, { az_index = i })
    }
  ]...)

  tags = {
    GitRepo = var.tags_git_repo
  }
}

################################################################################
# Cluster
################################################################################

# https://github.com/terraform-aws-modules/terraform-aws-eks/blob/master/examples/eks-managed-node-group/eks-al2023.tf
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.26.0"

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
    # Node health conditions that node_repair_config (below) acts on:
    # https://docs.aws.amazon.com/eks/latest/userguide/node-health.html
    eks-node-monitoring-agent = {
      addon_version = var.eks_addon_version_eks-node-monitoring-agent
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

  # Every control-plane log type, audit included; the module default omits
  # controllerManager and scheduler. Supports SOC 2 CC7.2 (System Monitoring)
  # and ISO/IEC 27001:2022 Annex A 8.15 (Logging).
  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # A year of control-plane logs (module default: 90 days) covers a 12-month
  # SOC 2 Type II observation period. Supports SOC 2 CC7.2 (System Monitoring)
  # and ISO/IEC 27001:2022 Annex A 8.15 (Logging).
  cloudwatch_log_group_retention_in_days = 365

  # Private endpoint for defense in depth: reaching the API needs in-VPC access
  # (VPN or bastion). In-cluster config lives in fluxcd-template, reconciled by
  # Flux, so nothing here needs a public endpoint.
  endpoint_public_access = false

  # SSO permission sets map to access policies in data.tf
  # (local.sso_access_entries); add new ones there, not here.
  access_entries = local.sso_access_entries

  # Give the Terraform identity admin access to the cluster
  # which will allow resources to be deployed into the cluster
  enable_cluster_creator_admin_permissions = true

  # Karpenter's EC2NodeClass picks its security group by this tag. Tag only
  # the node SG: Karpenter attaches every SG that carries the key.
  node_security_group_tags = {
    "karpenter.sh/discovery" = local.name
  }

  node_security_group_additional_rules = {
    # `kubectl cnpg status` makes the API server dial each instance's status
    # port (8000) through pods/proxy; the default node SG drops that, and the
    # plugin hangs.
    ingress_cluster_to_cnpg_status = {
      description                   = "API server to CloudNativePG instance manager (kubectl cnpg status uses pods/proxy on port 8000)"
      protocol                      = "tcp"
      from_port                     = 8000
      to_port                       = 8000
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # One group per AZ, so each version update drains its own zone and a drain
  # blocked in one zone doesn't hold up the others. In-place updates only; for
  # replacements see docs/changing-instance-types.md.
  eks_managed_node_groups = {
    for key, group in local.node_groups : key => {

      # Pin to this zone's private subnet. local.availability_zones is a prefix
      # of local.azs, so the indexes match module.vpc.private_subnets.
      subnet_ids = [module.vpc.private_subnets[group.az_index]]

      # Required for the KMS-encrypted root volume in block_device_mappings,
      # which replaces disk_size.
      use_custom_launch_template = true

      # Replaces the former `disk_size = 50`. Encrypt the root volume with the
      # customer-managed EBS key (the ASG service-linked role is already granted
      # use of it in module.ebs_kms_key). AL2023's root device is /dev/xvda.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            encrypted             = true
            kms_key_id            = module.ebs_kms_key.key_arn
            delete_on_termination = true
          }
        }
      }

      # Replace nodes that stay NotReady or report faults, which EC2 status
      # checks alone miss (e.g. a starved kubelet).
      node_repair_config = {
        enabled = true
      }

      # instance_types = ["t4g.large"]
      # ami_type       = "AL2023_ARM_64_STANDARD"
      # The type lives in local.node_group_generations (top of this file).
      instance_types = group.instance_types

      # Pinned so a new EKS AMI isn't a node rotation on an unrelated PR. Bump
      # with ./update_node_ami.sh, alongside cluster_version. Only honoured
      # with use_latest_ami_release_version = false.
      ami_release_version            = var.node_ami_release_version
      use_latest_ami_release_version = false

      # One node per zone; three groups make the same three nodes as before.
      min_size = 1
      max_size = 1
      # This value is ignored after the initial creation
      # https://github.com/bryantbiggs/eks-desired-size-hack
      desired_size = 1

      # Reserved for workloads that must not ride Karpenter capacity, such as
      # the controllers that bootstrap scheduling. Pods and DaemonSets that run
      # here need a CriticalAddonsOnly toleration (karpenter and coredns do).
      taints = {
        critical_addons_only = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }

  }
}

################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  # All VPC traffic to the S3 bucket in flow-logs.tf, cheaper than CloudWatch
  # Logs. Supports SOC 2 CC7.2 (System Monitoring) and ISO/IEC 27001:2022
  # Annex A 8.15 (Logging) / 8.16 (Monitoring activities).
  enable_flow_log                      = true
  flow_log_destination_type            = "s3"
  flow_log_destination_arn             = aws_s3_bucket.flow_logs.arn
  create_flow_log_cloudwatch_iam_role  = false
  create_flow_log_cloudwatch_log_group = false
  flow_log_traffic_type                = "ALL"

  # Bill flow logs at the finest granularity (module default is 600s). One-minute
  # aggregation gives more precise timelines for security investigations.
  flow_log_max_aggregation_interval = 60

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
    # Karpenter's EC2NodeClass picks subnets by this tag; private subnets
    # only.
    "karpenter.sh/discovery" = local.name
  }
}

module "efs" {
  source  = "terraform-aws-modules/efs/aws"
  version = "2.2.1"

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
  version = "4.2.2"

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
  version = "6.8.2"

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
  version = "6.8.2"

  attach_efs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:efs-csi-controller-sa"]
    }
  }
  use_name_prefix = true
}
