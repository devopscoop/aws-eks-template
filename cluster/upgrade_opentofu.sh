#!/usr/bin/env bash

# Upgrades the OpenTofu version used by this cluster config to the latest stable
# release. Asks tenv for the newest stable version, writes it to the
# .opentofu-version file (read by tenv locally and by setup-opentofu in CI) and
# the required_version guard in versions.tf, then installs it via tenv.
#
# Usage:
#
#   ./upgrade_opentofu.sh

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
# Not using "-x" because we aren't debugging.
set -Eeuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Latest stable version, sorted descending so the newest is first. awk strips the
# trailing "(installed)" annotation tenv adds to versions already on disk.
version=$(tenv tofu list-remote --stable --descending --quiet | awk 'NR==1{print $1}')

if [[ -z "$version" ]]; then
  echo "Could not determine the latest OpenTofu version from tenv." >&2
  exit 1
fi

echo "Upgrading OpenTofu to ${version}"

echo "$version" > "${SCRIPT_DIR}/.opentofu-version"

sed -i.bak -E "s/^([ \t]*required_version[ \t]*=[ \t]*).*/\1\"${version}\"/" "${SCRIPT_DIR}/versions.tf"
rm "${SCRIPT_DIR}/versions.tf.bak"

# Install the new version locally. tenv reads .opentofu-version when running tofu.
tenv tofu install "$version"
