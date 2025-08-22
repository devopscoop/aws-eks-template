#!/usr/bin/env bash

if [[ $# -ne 2 ]]; then
  cat <<EOF >&2

Usage:

  $0 cluster_name domain github_org region

For example:

  #0 project1-dev devops.coop devopscoop us-east-2

EOF
  exit 1
fi

export cluster_name=$1
export domain=$2
export github_org=$3
export region=$4

grep -rIl --exclude-dir .git --exclude-dir .terraform project1-dev | xargs sed -i "s/us-east-2/${cluster_name}/g"
grep -rIl --exclude-dir .git --exclude-dir .terraform devops.coop | xargs sed -i "s/devops.coop/${domain}/g"
grep -rIl --exclude-dir .git --exclude-dir .terraform devopscoop cluster | xargs sed -i "s/devopscoop/${github_org}/g"
grep -rIl --exclude-dir .git --exclude-dir .terraform us-east-2 | xargs sed -i "s/us-east-2/${region}/g"
