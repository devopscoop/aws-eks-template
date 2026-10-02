#!/usr/bin/env bash

# Pins the cluster's nodes to the newest AL2023 EKS-optimized AMI release for
# cluster_version. Nodes come from two places, and both get the same release:
#
# - The managed node groups (main.tf): node_ami_release_version in this
#   directory's tfvars is rewritten in place, for you to commit.
# - Karpenter: fluxcd-template pins its EC2NodeClasses with
#   `alias: al2023@vYYYYMMDD` in apps/karpenter-custom-resources/. That lives
#   in another repo, so this opens a PR in devopscoop/fluxcd-template (or
#   prints the one already open). Merging it drifts every Karpenter node, and
#   Karpenter replaces them at the pace each NodePool's disruption budget
#   allows. Opening it needs `gh auth login` and push access to that repo.

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
# Not using "-x" because we aren't debugging.
set -Eeuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

karpenter_dir=apps/karpenter-custom-resources

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

# A release version is <Kubernetes patch>-<YYYYMMDD> (1.35.8-20260930), and
# Karpenter's alias takes that date as vYYYYMMDD, the AMI name's suffix
# (amazon-eks-node-al2023-x86_64-standard-1.35-v20260930). Deriving it rather
# than reading the image_name parameter guarantees both node sources match.
ami_version="v${release_version##*-}"

# A malformed version would make Karpenter fail to resolve any AMI, and then it
# can't launch nodes at all.
[[ "${ami_version}" =~ ^v[0-9]{8}$ ]] || { echo "ERROR: no AMI version in release '${release_version}'." >&2; exit 1; }

# One branch per release, so a rerun finds the PR it already opened.
branch="karpenter-ami-${ami_version}"
pr_url=$(gh pr list --repo devopscoop/fluxcd-template --head "${branch}" --state open --json url --jq '.[0].url // empty')
if [[ -n "${pr_url}" ]]; then
  echo "al2023@${ami_version} (Karpenter): already open as ${pr_url}"
  exit 0
fi

work_dir=$(mktemp -d)
trap 'rm -rf "${work_dir}"' EXIT
git clone --quiet --depth 1 git@github.com:devopscoop/fluxcd-template.git "${work_dir}"

files=$(git -C "${work_dir}" grep -lE 'alias: al2023@' -- "${karpenter_dir}/*.yaml") \
  || { echo "ERROR: no 'alias: al2023@' in fluxcd-template's ${karpenter_dir}/*.yaml." >&2; exit 1; }
old_aliases=$(git -C "${work_dir}" grep -hoE 'alias: al2023@[^[:space:]]+' -- "${karpenter_dir}/*.yaml" \
  | sed 's/^alias: //' | sort -u | paste -sd ' ' -)

while IFS= read -r file; do
  sed -i.bak -E "s/(alias: al2023@)[^[:space:]]+/\1${ami_version}/" "${work_dir}/${file}"
  rm "${work_dir}/${file}.bak"
done <<< "$files"

if git -C "${work_dir}" diff --quiet; then
  echo "al2023@${ami_version} (Karpenter): fluxcd-template already pins it"
  exit 0
fi

title="karpenter: pin the EC2NodeClass AMI to al2023@${ami_version}"
git -C "${work_dir}" switch --quiet -c "${branch}"
git -C "${work_dir}" commit --quiet -a -F - <<EOF
${title}

The newest AL2023 EKS-optimized release for EKS ${cluster_version}, and the
one aws-eks-template's managed node groups now pin
(node_ami_release_version = "${release_version}"). Opened by
aws-eks-template's cluster/update_node_ami.sh.
EOF
git -C "${work_dir}" push --quiet origin "${branch}"

pr_url=$(gh pr create --repo devopscoop/fluxcd-template --head "${branch}" --title "${title}" --body-file - <<EOF
Pins every EC2NodeClass in \`${karpenter_dir}/\` to \`al2023@${ami_version}\` (was \`${old_aliases}\`): the newest AL2023 EKS-optimized release for EKS ${cluster_version}, and the release aws-eks-template's managed node groups now pin (\`node_ami_release_version = "${release_version}"\`).

Merging this drifts every Karpenter node, and Karpenter replaces them at the pace each NodePool's disruption budget allows.

Opened by aws-eks-template's \`cluster/update_node_ami.sh\`.
EOF
)
echo "al2023@${ami_version} (Karpenter): opened ${pr_url}"
