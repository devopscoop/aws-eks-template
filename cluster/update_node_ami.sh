#!/usr/bin/env bash

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
# Not using "-x" because we aren't debugging.
set -Eeuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Don't hardcode terraform.tfvars: forks rename it (e.g. prod.auto.tfvars),
# which silently turned this script into a no-op.
tfvars_file=$(grep -lE '^node_ami_release_version' "${SCRIPT_DIR}"/*.tfvars)

AWS_REGION=$(sed -nE "s/^region[^=]*=[ \t]+['\"]?([^'\"]+)['\"]?/\1/p" "$tfvars_file")
export AWS_REGION
cluster_version=$(sed -nE "s/^cluster_version[^=]*=[ \t]+['\"]?([^'\"]+)['\"]?/\1/p" "$tfvars_file")

# AWS publishes the EKS-optimized AMI metadata as public SSM parameters, one
# tree per AMI family and architecture. The path below must match the node
# groups' ami_type in main.tf: AL2023_x86_64_STANDARD is the module default, so
# swap x86_64 for arm64 here if you uncomment the ARM ami_type there.
#
# A release version belongs to exactly one Kubernetes minor, which is why this
# reads cluster_version rather than taking an argument — bump cluster_version
# first, then run this, and commit the two together.
release_version=$(aws ssm get-parameter \
  --name "/aws/service/eks/optimized-ami/${cluster_version}/amazon-linux-2023/x86_64/standard/recommended/release_version" \
  --query Parameter.Value --output text)

sed -i.bak -E "s/^node_ami_release_version[^=]*=[ \t]+['\"]?([^'\"]+)['\"]?/node_ami_release_version = \"${release_version}\"/" "$tfvars_file"
rm "${tfvars_file}.bak"

tofu fmt "$tfvars_file"

echo "node_ami_release_version = \"${release_version}\" (EKS ${cluster_version}, ${AWS_REGION})"
