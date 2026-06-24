bucket = "project1-dev-tf-state-us-east-2"

# These should be the same as the ones in bootstrap/terraform.tfvars.
cluster_name = "project1-dev"
org_name     = "devopscoop"
region       = "us-east-2"
# Region that the Loki S3 buckets replicate to for cross-region redundancy.
replica_region = "us-west-2"

cluster_version = "1.35"

# Use the update_eks_addons.sh script in this directory to automatically update all EKS addon versions in this file.
eks_addon_version_aws-ebs-csi-driver     = "v1.60.1-eksbuild.1"
eks_addon_version_aws-efs-csi-driver     = "v3.2.0-eksbuild.1"
eks_addon_version_snapshot-controller    = "v8.5.0-eksbuild.5"
eks_addon_version_coredns                = "v1.14.3-eksbuild.2"
eks_addon_version_eks-pod-identity-agent = "v1.3.10-eksbuild.3"
eks_addon_version_kube-proxy             = "v1.35.3-eksbuild.11"
eks_addon_version_vpc-cni                = "v1.22.1-eksbuild.2"

enable_image_reflector_controller = true
enable_route53                    = true
create_route53_zone               = true

tags_git_repo = "github.com/devopscoop/project1-dev"
# AWS VPCs require a primary IPv4 CIDR even when using IPv6. The IPv6 CIDR is Amazon-provided.
vpc_cidr  = "10.0.0.0/16"
zone_name = "project1-dev.devops.coop"
