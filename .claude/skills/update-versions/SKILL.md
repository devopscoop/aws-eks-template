---
name: update-versions
description: Bump every version pin in this EKS cluster config by running the cluster/ update scripts in dependency order (update_opentofu.sh, update_eks_version.sh, update_eks_addons.sh, update_node_ami.sh, the last of which also opens the matching Karpenter AMI PR in fluxcd-template), then validate and report old → new. Use whenever the user asks to update, upgrade, or bump versions, refresh pins, run "the update scripts", do routine version maintenance, or upgrade OpenTofu, EKS/Kubernetes, the EKS add-ons, or the node AMI. Use it even when they name only one of those, because the scripts read each other's output.
---

# Update every version pin

Four scripts in `cluster/` each rewrite one kind of pin. They find their files from their own path, so the working directory doesn't matter. Each can run alone, but two of them look versions up *for* `cluster_version`, so run them in this order:

| # | Script | Rewrites | Why this position |
| - | ------ | -------- | ----------------- |
| 1 | `update_opentofu.sh` | `.opentofu-version` and `required_version` in `versions.tf`, then installs that version with tenv | Doesn't depend on the others. Running it first means the `tofu fmt` the other scripts run uses the new version. |
| 2 | `update_eks_version.sh` | `cluster_version` in the tfvars | 3 and 4 read `cluster_version`, so it has to be final before they run. |
| 3 | `update_eks_addons.sh` | every `eks_addon_version_*` in the tfvars | Latest add-on build for `cluster_version`. |
| 4 | `update_node_ami.sh` | `node_ami_release_version` in the tfvars, plus a fluxcd-template PR pinning Karpenter's `alias: al2023@vYYYYMMDD` to the same release | An AMI release exists for only one Kubernetes minor. |

If the user asks for only some of them, run just those, in the same order.

## Before running

1. **Start from a clean tree.** Run `git status --porcelain -- cluster/`. If `.opentofu-version`, `versions.tf`, or a `*.tfvars` already has uncommitted changes, ask before you continue. The report is built from `git diff`, and the user's own edits would end up in it.
2. **Pick an AWS profile.** Every AWS call these scripts make reads regional metadata that's the same in every account (`eks:DescribeClusterVersions`, `eks:DescribeAddonVersions`, and `ssm:GetParameter` on AWS's public AMI parameters), so a read-only profile is enough. Use the least-privileged one. If the user's instructions name a profile for this environment, use that one; otherwise ask. Bash calls don't share environment variables, so prefix every command with `AWS_PROFILE=<profile>` instead of exporting it once. Check the profile with `AWS_PROFILE=<profile> aws sts get-caller-identity`. If it fails, the SSO session has usually expired and the user needs to log in again (the README covers aws-sso).
3. **Check GitHub access.** Only script 4 needs it. Run `gh auth status`. The script also needs SSH push access to `devopscoop/fluxcd-template`, because it clones over `git@github.com:`.
4. **Write down the current `cluster_version`.** You need it after step 2.

The tools (`tenv`, `aws`, `jq`, `gh`, `git`) are all in the Brewfile and pkglist.txt. If one is missing, tell the user to run `brew bundle` (or the pkglist.txt equivalent) instead of installing it some other way.

## Running

Stop at the first failure and show its error. Don't work around a failure by hand-editing the value. Each script does the lookup that makes its value correct (for example, the AMI release has to belong to `cluster_version`'s minor), and a guessed pin is worse than a stale one. Tell the user which files the earlier scripts already changed.

There's one exception. Script 1 is independent of the others, so if it fails, run `git checkout -- cluster/.opentofu-version cluster/versions.tf` and carry on with 2–4. The tree was clean when you started, so this only discards the script's half-finished write. Leaving that write in place would point tenv at a version that isn't installed and break the `tofu fmt` that scripts 2–4 run.

### After `update_eks_version.sh`: check whether it moved

EKS upgrades the control plane one minor version at a time, so the script moves `cluster_version` up by one offered version at most. When EKS offers something newer still, it prints a second line naming it. Compare the new `cluster_version` with the one you wrote down:

- **Unchanged:** carry on.
- **One minor higher:** carry on, and lead the report with it (see below). If the script named a newer version, tell the user that reaching it takes another run after this one is applied.

Run 3 and 4 in the same pass even when `cluster_version` moved. Don't hold them back for a later apply. They look pins up for the new minor, and the apply already runs in upgrade order: the add-ons and the first node group wait on the control plane, and each later node group waits on the one before it. Holding back 4 would break the apply. The node groups take their Kubernetes version from the control plane, so they would ask EKS for the new minor with an AMI release from the old one.

A Kubernetes minor bump is the biggest change this skill can make: the control plane upgrades and every node is replaced. If the cluster already exists, look for upgrade blockers:

```shell
AWS_PROFILE=<profile> aws eks list-insights --region <region> --cluster-name <cluster_name> \
  --filter 'categories=UPGRADE_READINESS,kubernetesVersions=<new minor>'
```

Use the `region` and `cluster_name` values from the tfvars. Report any insight whose status isn't `PASSING`; `aws eks describe-insight --id ...` gives the details. A `ResourceNotFoundException` means the cluster hasn't been created yet (in the upstream template it never is), so skip this check. Also remind the user that the Helm releases in fluxcd-template have to support the new minor before this is applied, Karpenter most of all, because each Karpenter release supports a fixed range of Kubernetes versions.

### `update_node_ami.sh` opens a PR in another repo

This script pushes a `karpenter-ami-vYYYYMMDD` branch to fluxcd-template and opens a PR. If that PR is already open, or fluxcd-template already pins the release, it reports that and stops, so rerunning it is safe. A request to run the update scripts includes this PR, because the PR keeps Karpenter's nodes on the same AMI as the managed node groups. The script has no local-only mode. If the user asked for local changes only, or said not to open PRs, skip the script and say that you skipped it.

## Verify

From `cluster/`:

```shell
tofu fmt -recursive -check
tofu init -backend=false -input=false
tofu validate -no-color
```

`-backend=false` lets init run without access to the S3 state bucket, which validate doesn't need. These commands test the new OpenTofu version against the config. `validate` never reads tfvars, though, so it checks none of the new pins. Only `tofu plan` exercises them, and CI posts a plan when a PR touching `cluster/**` is opened. Say so in the report instead of implying that the pins were verified.

## Report

Start with a table built from `git diff -- cluster/`:

| Pin | Before | After |
| --- | ------ | ----- |

List pins that were already current on one line under the table instead of giving each a row. Then cover:

- **The fluxcd-template PR:** its URL, or "already open", or "already pinned".
- **A `cluster_version` change:** that it means a control-plane upgrade plus a full node replacement, the newer version EKS offers if the script named one, and any upgrade insights that came back. Also say to merge the fluxcd-template PR only *after* this repo's change is applied. Karpenter resolves the alias for the cluster's current minor, but the release date came from the new minor.
- **A `node_ami_release_version` change:** applying it replaces the managed node groups, which are the nodes the CNPG databases run on. The comment on `ami_release_version` in `main.tf` explains why that replacement should be a reviewable change and not something that slips in, so the PR description should say it.
- **What was verified:** fmt and validate passed or failed. The plan hasn't run.

## Committing

Don't branch, commit, or push unless the user asks. Merging to `main` makes CI apply the change, and AGENTS.md warns against pushing early. If the user does ask, branch off `main` first, and put `cluster_version` and `node_ami_release_version` in the same commit. If they're split, one commit pins nodes to an AMI built for a minor the control plane isn't running.
