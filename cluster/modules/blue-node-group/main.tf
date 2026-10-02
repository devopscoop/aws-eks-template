# One blue node group. cluster/main.tf calls this three times, chained
# through time_sleep gates so the groups update one at a time.
module "node_group" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "21.26.0"

  name       = var.name
  subnet_ids = [var.subnet_id]

  kubernetes_version  = var.kubernetes_version
  ami_release_version = var.ami_release_version
  # The module ignores the pin unless this is off.
  use_latest_ami_release_version = false

  cluster_name           = var.cluster.name
  cluster_endpoint       = var.cluster.endpoint
  cluster_auth_base64    = var.cluster.certificate_authority_data
  cluster_service_cidr   = var.cluster.service_cidr
  cluster_ip_family      = var.cluster.ip_family
  vpc_security_group_ids = [var.cluster.node_security_group_id]

  # Must match what module.eks generated, or the launch template changes.
  launch_template_name        = var.name
  launch_template_description = "Custom launch template for ${var.name} EKS managed node group"

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
        kms_key_id            = var.ebs_kms_key_arn
        delete_on_termination = true
      }
    }
  }

  # Let EKS replace nodes that stay unhealthy (Ready stuck False/Unknown,
  # or faults reported by the eks-node-monitoring-agent addon in cluster/main.tf). The
  # ASG alone cannot catch this: a kubelet can crash or starve — e.g. a
  # burstable instance out of CPU credits — while EC2 status checks keep
  # passing, so the instance sits NotReady until someone terminates it by
  # hand.
  node_repair_config = {
    enabled = true
  }

  instance_types = var.instance_types

  # One node per zone.
  min_size = 1
  max_size = 1
  # This value is ignored after the initial creation
  # https://github.com/bryantbiggs/eks-desired-size-hack
  desired_size = 1

  # Blue is reserved for workloads that must not ride Karpenter capacity:
  # CNPG database instances (consolidation and drift drains force a
  # switchover whenever the bin-packer rearranges nodes) and the
  # controllers that bootstrap scheduling itself. karpenter and coredns
  # tolerate this taint out of the box; the cnpg-database template's
  # karpenter marker block (fluxcd repo, apps/templates/cnpg-database)
  # adds the matching toleration alongside the node affinity that pins
  # databases here. Everything else drifts to Karpenter nodes as pods
  # restart: EKS applies taint updates to existing group nodes in place
  # (no node rotation), and a NO_SCHEDULE taint never evicts running
  # pods. DaemonSets need the toleration too — one that lacks it keeps
  # its running pods but stops scheduling onto REPLACEMENT blue nodes.
  taints = {
    critical_addons_only = {
      key    = "CriticalAddonsOnly"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }
}
