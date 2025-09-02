admin_email     = "hostmaster@devops.coop"
backend_s3_key  = "project1-dev/terraform.tfstate"
cluster_name    = "project1-dev"
cluster_version = "1.33"
dynamodb_table  = "terraform-state-lock"

# Use the update_eks_addons.sh script in this directory to automatically update all EKS addon versions in this file.
eks_addon_version_aws-ebs-csi-driver     = "v1.48.0-eksbuild.1"
eks_addon_version_coredns                = "v1.12.3-eksbuild.1"
eks_addon_version_eks-pod-identity-agent = "v1.3.8-eksbuild.2"
eks_addon_version_kube-proxy             = "v1.33.3-eksbuild.6"
eks_addon_version_vpc-cni                = "v1.20.1-eksbuild.3"

enable_route53 = true

# This should be the same region as the one in bootstrap/terraform.tfvars.
region = "us-east-2"

tags_git_repo = "github.com/devopscoop/project1-dev"
tf_bucket     = "project1-dev-tf-state-us-east-2"
vpc_cidr      = "10.0.0.0/16"
zone_name     = "project1-dev.devops.coop"
