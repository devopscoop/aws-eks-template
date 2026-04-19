#!/usr/bin/env bash

if [[ $# -ne 4 ]]; then
  cat <<EOF >&2

Usage:

  $0 cluster_name domain github_org region method

Where:

  method: subtree or fork

For example:

  $0 project1-dev devops.coop devopscoop us-east-2 subtree

EOF
  exit 1
fi

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
export SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Need to know the name of the top level dir in this git repo so we can copy GitHub workflow files to the right place.
export git_top_dir=$(git rev-parse --show-toplevel)

export cluster_name=$1
export domain=$2
export github_org=$3
export region=$4
export method=$5

export EXCLUDES="--exclude-dir .git --exclude-dir .terraform --exclude LICENSE --exclude README.md --exclude quickstart.sh"

grep -rIl ${EXCLUDES} project1-dev "${SCRIPT_DIR}" | xargs perl -pi -e "s/project1-dev/${cluster_name}/g"
grep -rIl ${EXCLUDES} devops.coop "${SCRIPT_DIR}" | xargs perl -pi -e "s/devops.coop/${domain}/g"
grep -rIl ${EXCLUDES} devopscoop "${SCRIPT_DIR}" | xargs perl -pi -e "s/devopscoop/${github_org}/g"
grep -rIl ${EXCLUDES} us-east-2 "${SCRIPT_DIR}" | xargs perl -pi -e "s/us-east-2/${region}/g"

if [[ "$method" == "subtree" ]]; then
  cp "${SCRIPT_DIR}/.github/workflows/opentofu.yml" "${git_top_dir}/.github/workflows/opentofu-${cluster_name}.yml"
fi
