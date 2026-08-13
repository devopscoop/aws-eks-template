#!/usr/bin/env bash

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
# Not using "-x" because we aren't debugging.
set -Eeuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Don't hardcode terraform.tfvars: forks rename it (e.g. prod.auto.tfvars),
# which silently turned this script into a no-op. Instead, target whichever
# single tfvars file carries the eks_addon_version_* pins.
tfvars_file=$(grep -lE '^eks_addon_version_' "${SCRIPT_DIR}"/*.tfvars || true)
if [ -z "$tfvars_file" ]; then
  echo "error: no *.tfvars file with eks_addon_version_* pins found in ${SCRIPT_DIR}" >&2
  exit 1
fi
if [ "$(wc -l <<< "$tfvars_file")" -ne 1 ]; then
  echo "error: multiple tfvars files with eks_addon_version_* pins; expected exactly one:" >&2
  echo "$tfvars_file" >&2
  exit 1
fi

AWS_REGION=$(sed -nE "s/^region[^=]*=[ \t]+['\"]?([^'\"]+)['\"]?/\1/p" "$tfvars_file")
export AWS_REGION
cluster_version=$(sed -nE "s/^cluster_version[^=]*=[ \t]+['\"]?([^'\"]+)['\"]?/\1/p" "$tfvars_file")
export cluster_version

for eks_addon in $(sed -nE 's/^eks_addon_version_([A-Za-z0-9-]+).*/\1/p' "$tfvars_file"); do
  # echo "eks_addon_version_${eks_addon} = \"$(aws eks describe-addon-versions --addon-name "$eks_addon" --kubernetes-version "$cluster_version" --query "addons[].addonVersions[].addonVersion" | jq -r '.[0]')\""
  eks_addon_version=$(aws eks describe-addon-versions --addon-name "$eks_addon" --kubernetes-version "$cluster_version" --query "addons[].addonVersions[].addonVersion" | jq -r '.[0]')
  sed -i.bak -E "s/^eks_addon_version_${eks_addon}[^=]*=[ \t]+['\"]?([^'\"]+)['\"]?/eks_addon_version_${eks_addon} = \"${eks_addon_version}\"/" "$tfvars_file"
  rm "${tfvars_file}.bak"
done

tofu fmt "$tfvars_file"
