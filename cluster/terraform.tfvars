admin_email     = "project1@devops.coop"
backend_s3_key  = "project1-dev/terraform.tfstate"
cluster_name    = "project1-dev"
cluster_version = "1.33"

# If you changed dynamodb_table_name in bootstrap/terraform.tfvars, set this to the same value.
# dynamodb_table = "project1-dev-terraform-state-lock"

# Use the update_eks_addons.sh script in this directory to automatically update all EKS addon versions in this file.
eks_addon_version_aws-ebs-csi-driver = "v1.47.0-eksbuild.1"
eks_addon_version_coredns            = "v1.12.2-eksbuild.4"
eks_addon_version_kube-proxy         = "v1.33.3-eksbuild.4"
eks_addon_version_vpc-cni            = "v1.20.1-eksbuild.1"

github_repos  = ["repo:devopscoop/project1-dev:*", ]
region        = "us-east-2"
tags_git_repo = "github.com/devopscoop/project1-dev"
tf_bucket     = "project1-dev-tf-state-us-east-2"
vpc_cidr      = "10.0.0.0/16"
zone_name     = "project1-dev.devops.coop"
