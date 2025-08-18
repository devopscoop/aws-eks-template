#!/usr/bin/env bash

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
# Not using "-x" because we aren't debugging.
set -Eeuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

export AWS_REGION=$(sed -nE "s/^region[^=]*=[ \t]+['\"]?([^'\"]+)['\"]?/\1/p" "${SCRIPT_DIR}/terraform.tfvars")
export cluster_version=$(sed -nE "s/^cluster_version[^=]*=[ \t]+['\"]?([^'\"]+)['\"]?/\1/p" "${SCRIPT_DIR}/terraform.tfvars")
for eks_addon in aws-ebs-csi-driver coredns kube-proxy vpc-cni; do
  # echo "eks_addon_version_${eks_addon} = \"$(aws eks describe-addon-versions --addon-name "$eks_addon" --kubernetes-version "$cluster_version" --query "addons[].addonVersions[].addonVersion" | jq -r '.[0]')\""
  eks_addon_version=$(aws eks describe-addon-versions --addon-name "$eks_addon" --kubernetes-version "$cluster_version" --query "addons[].addonVersions[].addonVersion" | jq -r '.[0]')
  sed -i.bak -E "s/^eks_addon_version_${eks_addon}[^=]*=[ \t]+['\"]?([^'\"]+)['\"]?/eks_addon_version_${eks_addon} = \"${eks_addon_version}\"/" "${SCRIPT_DIR}/terraform.tfvars"
  rm "${SCRIPT_DIR}/terraform.tfvars.bak"
done
tofu fmt "${SCRIPT_DIR}/terraform.tfvars"
