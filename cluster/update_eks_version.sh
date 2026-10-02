#!/usr/bin/env bash

# Steps cluster_version up to the next Kubernetes version EKS offers. EKS
# upgrades the control plane one minor at a time, so writing the newest version
# would ask for a jump EKS refuses; reaching a version further ahead takes one
# run per minor, each applied before the next.
# https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html
#
# Run ./update_eks_addons.sh and ./update_node_ami.sh afterwards and commit all
# three together. Add-on builds and AMI releases are looked up for one minor,
# and module.eks applies them in upgrade order anyway: the node groups wait on
# the control plane, and the add-ons wait on the node groups.

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

current_version=$(sed -nE "s/^cluster_version[^=]*=[ \t]+['\"]?([^'\"]+)['\"]?/\1/p" "$tfvars_file")

# Sort numerically by component; a lexical sort puts 1.9 above 1.10.
offered_versions=$(aws eks describe-cluster-versions --output json \
  | jq -c '[.clusterVersions[].clusterVersion] | sort_by(split(".") | map(tonumber))')

# The lowest offered version above the current one. jq compares the
# [major, minor] arrays element by element, so this is numeric too.
cluster_version=$(jq -r --arg current "$current_version" '
  ($current | split(".") | map(tonumber)) as $c
  | map(select((split(".") | map(tonumber)) > $c)) | first // $current
' <<<"$offered_versions")
newest_version=$(jq -r 'last' <<<"$offered_versions")

sed -i.bak -E "s/^cluster_version[^=]*=[ \t]+['\"]?([^'\"]+)['\"]?/cluster_version = \"${cluster_version}\"/" "$tfvars_file"
rm "${tfvars_file}.bak"

tofu fmt "$tfvars_file"

echo "cluster_version = \"${cluster_version}\""
if [[ "$cluster_version" != "$newest_version" ]]; then
  echo "EKS offers up to ${newest_version}; run this again after ${cluster_version} is applied."
fi
