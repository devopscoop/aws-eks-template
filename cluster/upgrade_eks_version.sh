#!/usr/bin/env bash

# Writes the newest Kubernetes version EKS offers into cluster_version.
#
# Two things this deliberately does NOT do, because they are yours to judge:
# EKS upgrades one minor at a time, so step it by hand if this jumps you more
# than one; and an AMI release version exists for only one minor, so run
# ./update_node_ami.sh afterwards.

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
# Not using "-x" because we aren't debugging.
set -Eeuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Don't hardcode terraform.tfvars: forks rename it (e.g. prod.auto.tfvars),
# which silently turned update_eks_addons.sh into a no-op.
tfvars_file=$(grep -lE '^cluster_version' "${SCRIPT_DIR}"/*.tfvars)

AWS_REGION=$(sed -nE "s/^region[^=]*=[ \t]+['\"]?([^'\"]+)['\"]?/\1/p" "$tfvars_file")
export AWS_REGION

# Sort numerically by component; a lexical sort puts 1.9 above 1.10.
cluster_version=$(aws eks describe-cluster-versions --output json \
  | jq -r '[.clusterVersions[].clusterVersion] | sort_by(split(".") | map(tonumber)) | last')

sed -i.bak -E "s/^cluster_version[^=]*=[ \t]+['\"]?([^'\"]+)['\"]?/cluster_version = \"${cluster_version}\"/" "$tfvars_file"
rm "${tfvars_file}.bak"

tofu fmt "$tfvars_file"

echo "cluster_version = \"${cluster_version}\""
