#!/usr/bin/env bash

if [[ $# -ne 4 ]]; then
  cat <<EOF >&2

Usage:

  $0 cluster_name domain github_org region

For example:

  $0 project1-dev devops.coop devopscoop us-east-2

EOF
  exit 1
fi

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

export cluster_name=$1
export domain=$2
export github_org=$3
export region=$4

grep -rIl --exclude-dir .git --exclude-dir .terraform project1-dev "${SCRIPT_DIR}" | xargs perl -pi -e "s/us-east-2/${cluster_name}/g"
grep -rIl --exclude-dir .git --exclude-dir .terraform devops.coop "${SCRIPT_DIR}" | xargs perl -pi -e "s/devops.coop/${domain}/g"
grep -rIl --exclude-dir .git --exclude-dir .terraform devopscoop cluster "${SCRIPT_DIR}" | xargs perl -pi -e "s/devopscoop/${github_org}/g"
grep -rIl --exclude-dir .git --exclude-dir .terraform us-east-2 "${SCRIPT_DIR}" | xargs perl -pi -e "s/us-east-2/${region}/g"
