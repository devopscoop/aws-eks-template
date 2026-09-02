# diff --color=always -w -y -W200 <(curl -sL https://raw.githubusercontent.com/aws-ia/terraform-aws-eks-blueprints/main/patterns/stateful/main.tf) main.tf | less -R

provider "aws" {
  region = local.region

  # All the resources created by the aws provider will get all the local tags.
  default_tags {
    tags = local.tags
  }
}

# Second region, for cross-region S3 replication (replica_region in
# terraform.tfvars). Currently only the CNPG database backup buckets use it
# (cnpg-backups.tf, when cnpg_backup_replication is on); it lives here
# rather than with its first consumer so future replicated buckets can share
# it. Provider blocks can't be conditional, so it exists (unused) even when
# nothing replicates — harmless.
provider "aws" {
  alias  = "replica"
  region = var.replica_region

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
}

################################################################################
# Cluster
################################################################################

# https://github.com/terraform-aws-modules/terraform-aws-eks/blob/master/examples/eks-managed-node-group/eks-al2023.tf
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.25.0"

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
    # Publishes granular node health NodeConditions (kernel, networking,
    # storage faults) that node auto repair (node_repair_config on the node
    # group below) consumes to decide when to replace a node.
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

  # Emit all EKS control-plane log types to CloudWatch. The module default omits
  # controllerManager and scheduler; enabling every type (notably the audit log)
  # supports SOC 2 (CC7.2, System Monitoring) and ISO/IEC 27001:2022 Annex A 8.15
  # (Logging).
  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Retain the cluster's CloudWatch control-plane logs for a full year (module
  # default is 90 days). This supports SOC 2 audit logging under Trust Services
  # Criteria CC7.2 (System Monitoring) and ISO/IEC 27001:2022 Annex A 8.15
  # (Logging); 365 days covers the typical 12-month SOC 2 Type II observation
  # period.
  cloudwatch_log_group_retention_in_days = 365

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

  # Grant AWS SSO roles appropriate access to the cluster. The mapping of
  # AWSReservedSSO_* permission sets to cluster-access-policies is discovered
  # dynamically in data.tf (local.sso_access_entries); add new permission sets
  # there rather than hardcoding role ARNs here.
  access_entries = local.sso_access_entries

  # Give the Terraform identity admin access to the cluster
  # which will allow resources to be deployed into the cluster
  enable_cluster_creator_admin_permissions = true

  # Karpenter's EC2NodeClass discovers which security group to attach to the
  # nodes it launches by this tag (spec.securityGroupSelectorTerms in
  # fluxcd-template's apps/karpenter-custom-resources). Tag only the node
  # security group — tagging more than one SG with the same discovery key
  # makes Karpenter attach all of them.
  node_security_group_tags = {
    "karpenter.sh/discovery" = local.name
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    blue = {

      # A custom launch template is required to configure the root volume via
      # block_device_mappings (KMS-encrypted, below). This means
      # `disk_size`/`remote_access` can no longer be set directly — the disk is
      # configured via block_device_mappings below instead.
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

      # Let EKS replace nodes that stay unhealthy (Ready stuck False/Unknown,
      # or faults reported by the eks-node-monitoring-agent addon above). The
      # ASG alone cannot catch this: a kubelet can crash or starve — e.g. a
      # burstable instance out of CPU credits — while EC2 status checks keep
      # passing, so the instance sits NotReady until someone terminates it by
      # hand.
      node_repair_config = {
        enabled = true
      }

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
  version = "6.7.2"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  # Capture VPC Flow Logs for all traffic (accepted and rejected) to S3. S3 is
  # markedly cheaper than CloudWatch Logs for high-volume flow data. The bucket,
  # its log-delivery policy, and retention lifecycle are defined in
  # flow-logs.tf; the module only creates the aws_flow_log resource pointing at
  # that bucket, so the CloudWatch IAM role and log group are disabled here.
  # Network flow logging supports SOC 2 (CC7.2, System Monitoring) and ISO/IEC
  # 27001:2022 Annex A 8.15 (Logging) / 8.16 (Monitoring activities), and aids
  # incident investigation.
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
    # Karpenter's EC2NodeClass discovers which subnets to launch nodes into by
    # this tag (spec.subnetSelectorTerms in fluxcd-template's
    # apps/karpenter-custom-resources). Private subnets only — nodes never
    # belong in the public ones.
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
  version = "4.2.1"

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
  version = "6.8.1"

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
  version = "6.8.1"

  attach_efs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:efs-csi-controller-sa"]
    }
  }
  use_name_prefix = true
}
