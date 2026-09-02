# AGENTS.md

Instructions for AI coding agents working in this repo. `CLAUDE.md` is a symlink to this file — edit `AGENTS.md` and leave the symlink alone.

## What this repo is

A template for a production AWS EKS cluster. It is consumed either by *forking* it (one git repo per cluster) or by `git subtree`ing it into an existing infrastructure-as-code monorepo — see `docs/fork_vs_subtree.argdown` for the argument map. The checkout you are editing is either the upstream template or a cluster-specific copy of it.

Only AWS infrastructure lives here. Everything that runs *inside* Kubernetes (Helm releases, ClusterIssuers, StorageClasses, RBAC) lives in the companion `fluxcd-template` repo and is reconciled by Flux from inside the cluster.

## Architecture

### Two OpenTofu root modules

| Dir | State | Applied by |
| --- | --- | --- |
| `bootstrap/` | local `terraform.tfstate`, force-committed to git | a human, once, from a laptop |
| `cluster/` | S3 backend created by `bootstrap/`, with `use_lockfile` | GitHub Actions only |

`bootstrap/` wraps `trussworks/bootstrap/aws` to create the state bucket and the state-lock DynamoDB table. Its state files are committed with `git add -f` (they're covered by `.gitignore`) — deliberate, and only acceptable because this particular state contains no secrets.

`cluster/` is derived from `aws-ia/terraform-aws-eks-blueprints` `patterns/stateful`. `main.tf`, `versions.tf`, and `outputs.tf` carry a `diff <(curl -sL .../patterns/stateful/<file>) <file>` command in a header comment for re-syncing with upstream.

### The private API endpoint drives the file layout

`module.eks` sets `endpoint_public_access = false` (`main.tf`). CI runs outside the VPC and therefore cannot reach the Kubernetes API. Consequences:

- **Never add a `kubernetes`, `helm`, or `kubectl` provider to `cluster/`.** It may work from a laptop and will fail in CI. This constraint caused a major refactor already; the long comment on that setting explains it.
- The pattern for any in-cluster workload that needs AWS permissions is: create the IRSA role here, `output` its ARN, then paste that ARN into the matching `eks.amazonaws.com/role-arn` ServiceAccount annotation in fluxcd-template. See `cert-manager.tf`, `external-dns.tf`, `aws-load-balancer-controller.tf`, `image-reflector-controller.tf`, `loki.tf` — they are all the same 20-line shape.
- Outputs are this repo's interface with fluxcd-template (`efs_id`, `loki_bucket_names`, the `*_role_arn`s). Every one of them has a `description` naming the file it gets pasted into; keep that true when adding outputs.

Human cluster access comes from `local.sso_access_entries` in `data.tf`, which discovers `AWSReservedSSO_*` role ARNs by regex because those ARNs have a dynamic suffix. Add new permission sets there rather than hardcoding ARNs into `access_entries` in `main.tf`. Read-only SSO roles are also put in a `cluster-viewers` Kubernetes group so fluxcd-template can bind them to CRD view rights.

### Placeholder values and `quickstart.sh`

`quickstart.sh` converts the template into a real cluster config by string-replacing four literals across every text file in the repo:

`project1-dev` (cluster name) · `devops.coop` (domain) · `devopscoop` (GitHub org) · `us-east-2` (region)

New code must use those exact literals for those four concepts, or a fork will silently keep template values. `README.md`, `LICENSE`, `.git`, `.terraform`, and `quickstart.sh` itself are excluded from the replacement.

### Variables

`variables.tf` declares types and descriptions only — **no defaults**. Every value lives in `terraform.tfvars` so there is one place to look. `cluster_name` and `region` appear in both `bootstrap/terraform.tfvars` and `cluster/terraform.tfvars` and must match.

## Commands

OpenTofu is never installed directly: `tenv` supplies `tofu`, pinned by `cluster/.opentofu-version`. That version is duplicated in `required_version` in `cluster/versions.tf`, so change both with the script rather than by hand:

```shell
cd cluster && ./upgrade_opentofu.sh   # latest stable → .opentofu-version + versions.tf, then installs it via tenv
```

Everything else runs from `cluster/` with `AWS_PROFILE` exported (README covers aws-sso onboarding; never `aws configure`):

```shell
tofu init
tofu fmt -recursive -check    # CI reports this on the PR but does not fail on it
tofu validate -no-color
tofu plan -concise -no-color -input=false -out=plan.file
./update_eks_addons.sh        # rewrites every eks_addon_version_* in terraform.tfvars to the latest for cluster_version
zizmor .github/workflows      # audit workflows after changing them
```

There is no test suite. `fmt` / `validate` / `plan` are the entire verification story, and `plan` is the only step that catches real errors — so prefer changes a plan can actually exercise, and say so plainly when a change can only be validated by applying it.

## CI/CD

`.github/workflows/opentofu-aws-eks.yml` is the deploy path: a PR touching `cluster/**` gets a `tofu plan` posted as a PR comment; merging to `main` runs `tofu apply` on that saved plan. Credentials come from GitHub OIDC assuming the role created by the CloudFormation template in `configure-aws-credentials/`, which is applied by hand through the AWS console — it is what grants Terraform access to the account, so it cannot itself be Terraform.

- The job is skipped when `github.repository == 'devopscoop/aws-eks-template'`, because the template repo has no real cluster. Forks and subtrees run it normally.
- Don't push branches unless the task explicitly says to. A premature push either fails the pipeline or builds a misconfigured cluster; the README warns about this in several places.
- Third-party actions are pinned to full commit SHAs with a trailing `# vX.Y.Z` comment. Pin new ones the same way, and never interpolate `${{ ... }}` into an inline `script:` body — pass values through `env:` and read `process.env.*` (the workflow's zizmor template-injection comment explains why).
- Plan output is written to a file and `tee`d rather than passed through a step output, because large plans blow past `ARG_MAX`. PR comments are truncated at 63000 chars with a link to the artifact.
- Destroying a cluster means adding `-destroy` to the plan/apply lines in that workflow, not running destroy locally.

## Conventions

- Comments explain *why*, at length, and usually link the GitHub issue or AWS doc that forced the decision. Match that density: a surprising line should carry its reason.
- Compliance is a first-class justification. Logging and retention decisions cite SOC 2 (CC7.2) and ISO/IEC 27001:2022 Annex A 8.15/8.16, and 365 days is the house retention standard (EKS control-plane logs, VPC flow logs, Route 53 query logs) because it covers a 12-month SOC 2 Type II observation period.
- To take a resource out of scope for Vanta's automated tests, tag it `VantaNoAlert = "<reason>"` (see `flow-logs.tf`). It disables *every* Vanta test for that resource, not just the one that flagged it.
- Module and provider versions are pinned exactly (`version = "21.24.0"`, not `~>`). Dependabot bumps them weekly.
- Log/telemetry S3 buckets follow one shape: public access block, HTTPS-only bucket policy, and a lifecycle rule — deliberately no SSE configuration, because S3 has default-encrypted every new object with SSE-S3 since January 2023 and that floor can't be disabled (add one only for SSE-KMS). Copy an existing one (`flow-logs.tf`, `loki.tf`) rather than starting fresh.

## Package manifests

This repo ships a `Brewfile` (macOS: `brew bundle`) and a `pkglist.txt` (Arch Linux) that install every CLI tool the repo uses. Keep them in sync with the code:

- When you add a tool, script, or a new external command inside an existing script, add the package to BOTH files, with a comment noting what uses it.
- When a tool stops being used, remove it from both files.
- Verify package names before adding them: `brew info <formula>` for Homebrew, and the official repos/AUR for Arch. Names differ between ecosystems (e.g. kubectl is Homebrew `kubernetes-cli` but Arch `kubectl`; Homebrew `awscli` is Arch `aws-cli-v2`). If a package is AUR-only, note that in pkglist.txt's header instructions.
- Update the "Install required packages" section in README.md if the tool list changes.
- OpenTofu is managed by tenv (which reads `.opentofu-version`) — never add `opentofu` directly to the manifests.
