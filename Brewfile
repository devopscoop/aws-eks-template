# Brewfile for aws-eks-template
#
# Installs every CLI tool used or referenced by this repo.
# Usage: brew bundle

# AWS CLI (`aws`) - README onboarding, update_eks_addons.sh, `aws eks update-kubeconfig`
brew "awscli"

# AWS SSO CLI (`aws-sso`) - README onboarding; short-lived credentials instead of `aws configure`
brew "aws-sso-cli"

# tenv - version manager that installs/pins OpenTofu (`tofu`) from .opentofu-version.
# Per the README, do NOT install opentofu directly; tenv provides the `tofu` binary.
# Used by upgrade_opentofu.sh and for `tofu init/plan/apply` in bootstrap/ and cluster/.
brew "tenv"

# jq - JSON parsing in cluster/update_eks_addons.sh
brew "jq"

# kubectl - connecting to the cluster with the kubeconfig from `aws eks update-kubeconfig`
brew "kubernetes-cli"

# k9s - terminal UI for browsing and managing the EKS cluster
brew "k9s"

# git - fork/subtree workflow in the README, quickstart.sh
brew "git"

# zizmor - GitHub Actions workflow auditing, referenced in .github/workflows/opentofu-aws-eks.yml
brew "zizmor"

# bash - all repo scripts use `#!/usr/bin/env bash`
brew "bash"

# perl - in-place substitutions in quickstart.sh
brew "perl"

# Not available via Homebrew:
# - Argdown CLI (renders docs/fork_vs_subtree.argdown): npm install -g @argdown/cli
