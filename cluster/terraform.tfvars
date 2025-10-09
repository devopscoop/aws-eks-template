# These should be the same as the ones in bootstrap/terraform.tfvars.
cluster_name = "project1-dev"
region       = "us-east-2"

admin_email     = "hostmaster@devops.coop"
cluster_version = "1.34"

# Use the update_eks_addons.sh script in this directory to automatically update all EKS addon versions in this file.
eks_addon_version_aws-ebs-csi-driver     = "v1.49.0-eksbuild.1"
eks_addon_version_snapshot-controller    = "v8.3.0-eksbuild.1"
eks_addon_version_coredns                = "v1.12.4-eksbuild.1"
eks_addon_version_eks-pod-identity-agent = "v1.3.8-eksbuild.2"
eks_addon_version_kube-proxy             = "v1.34.0-eksbuild.4"
eks_addon_version_vpc-cni                = "v1.20.3-eksbuild.1"

enable_route53 = true

tags_git_repo = "github.com/devopscoop/project1-dev"
vpc_cidr      = "10.0.0.0/16"
zone_name     = "project1-dev.devops.coop"
