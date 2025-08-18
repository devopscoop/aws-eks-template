admin_email     = "project1@devops.coop"
backend_s3_key  = "project1-dev/terraform.tfstate"
cluster_name    = "project1-dev"
cluster_version = "1.33"

# If you changed dynamodb_table_name in bootstrap/terraform.tfvars, set this to the same value.
# dynamodb_table = "project1-dev-terraform-state-lock"

# Use this not-quite-one-liner to fetch the correct EKS addon versions:
# export AWS_REGION=$(sed -nE "s/^region[^=]*=[ \t]+['\"]?([^'\"]+)['\"]?/\1/p" terraform.tfvars)
# export cluster_version=$(sed -nE "s/^cluster_version[^=]*=[ \t]+['\"]?([^'\"]+)['\"]?/\1/p" terraform.tfvars)
# for eks_addon in aws-ebs-csi-driver coredns kube-proxy vpc-cni; do
#   echo "eks_addon_version_${eks_addon} = \"$(aws eks describe-addon-versions --addon-name "$eks_addon" --kubernetes-version "$cluster_version" --query "addons[].addonVersions[].addonVersion" | jq -r '.[0]')\""
# done
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
