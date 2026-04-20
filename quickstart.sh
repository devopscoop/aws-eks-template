#!/usr/bin/env bash

if [[ $# -ne 5 ]]; then
  cat <<EOF >&2

Usage:

  $0 cluster_name domain github_org region role_arn

For example:

  $0 project1-dev devops.coop devopscoop us-east-2 arn:aws:iam::999999999999:role/github-actions-project1-dev-Role-op9nZF6VBumT 

EOF
  exit 1
fi

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
export SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Need to know the name of the top level dir in this git repo so we can copy GitHub workflow files to the right place.
export git_top_dir=$(git rev-parse --show-toplevel)

if [[ "${SCRIPT_DIR}" == "${git_top_dir}" ]]; then
  export method='fork'
else
  export method='subtree'
fi

#TODO: checkout that git is in a clean state?

export cluster_name=$1
export domain=$2
export github_org=$3
export region=$4
export role_arn=$5

export EXCLUDES="--exclude-dir .git --exclude-dir .terraform --exclude LICENSE --exclude README.md --exclude quickstart.sh"

grep -rIl ${EXCLUDES} project1-dev "${SCRIPT_DIR}" | xargs perl -pi -e "s/project1-dev/${cluster_name}/g"
grep -rIl ${EXCLUDES} devops.coop "${SCRIPT_DIR}" | xargs perl -pi -e "s/devops.coop/${domain}/g"
grep -rIl ${EXCLUDES} devopscoop "${SCRIPT_DIR}" | xargs perl -pi -e "s/devopscoop/${github_org}/g"
grep -rIl ${EXCLUDES} us-east-2 "${SCRIPT_DIR}" | xargs perl -pi -e "s/us-east-2/${region}/g"

# Adding the AWS Role name to the GitHub Actions workflow.
perl -pi -e "s#role-to-assume:.*#role-to-assume: ${role_arn}#" "${SCRIPT_DIR}/.github/workflows/opentofu.yml"

if [[ "$method" == "subtree" ]]; then

  # Because this is a subtree, we need to copy the workflow to the root of the git repo for GitHub to use it. Adding $cluster_name to the filename to avoid a naming conflict.
  cp "${SCRIPT_DIR}/.github/workflows/opentofu.yml" "${git_top_dir}/.github/workflows/opentofu-${cluster_name}.yml"

  # Workflow paths need to be update to point to subtree directory (which is named $cluster_name)
  perl -pi -e "s# cluster# ${cluster_name}/cluster#" "${git_top_dir}/.github/workflows/opentofu-${cluster_name}.yml"

fi
