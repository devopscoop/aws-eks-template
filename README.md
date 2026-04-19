# aws-eks-template

This repo can be used to build a production-ready AWS EKS Kubernetes cluster. It can either be forked, or included in a monorepo à la carte with `git subtree`. There are four directories in this repo that should be processed in order:

1. **bootstrap**: creates an encrypted AWS S3 bucket for OpenTofu's state files, and a DynamoDB table for state locking.
1. **configure-aws-credentials**: creates an AWS Role that will be used by the CI/CD pipeline.
1. **cluster**: is executed by the CI/CD pipeline to create the cluster.
1. **examples**: has additional code to build more AWS resources if you need them.

## Prerequisites

- Do not install opentofu directly. Instead, use [tenv](https://github.com/tofuutils/tenv)

## Creating a cluster

> **WARNING**
> Don't `git push` any code unless there is an instruction to do so. If you push code too early, you will either get CI/CD pipeline errors, or you will accidentally build a misconfigured cluster.

### Quickstart

1. Choose a name for your new cluster. TODO: add link to naming things is easy doc in branch of website repo. Set an env var for the name:
   ```
   export cluster_name=YOUR_CLUSTERS_NAME
   ```
1. Choose an installation method - either Fork or Subtree:
   - Fork
      1. Click the "Fork" button in this repo to create a repo in your organization with the same name as the cluster you are creating.
   - Subtree
      1. Change directory to an existing repo.
      1. Create a branch:
         ```
         git checkout -b create_cluster
         ```
      1. Use subtree to add this repo as a subdirectory to your existing repo:
         ```
         git subtree add --prefix $cluster_name git@github.com:devopscoop/aws-eks-template.git main
         ```
1. Run the quickstart.sh script to replace default values with your organization's values:
   ```
   Usage:

      ./quickstart.sh cluster_name domain github_org region method

   Where:

      method: subtree or fork

   For example:

      ./quickstart.sh project1-dev devops.coop devopscoop us-east-2 subtree
   ```
1. Add and commit your files. If you are using a fork, you should be on the main branch right now. If you are using subtree, you should be in the create_cluster branch. Regardless, only commit, do not push yet:
   ```
   git add -A
   git commit -m "quickstart.sh"
   ```

### bootstrap

Based on:

- <https://github.com/trussworks/terraform-aws-bootstrap>
- <https://opentofu.org/docs/language/settings/backends/configuration/>

If you are using a subtree, you probably already have a place to put your OpenTofu state, so you can probably skip this section.

Process:

1. Change directory to `bootstrap`.
1. Verify that the values in `terraform.tfvars` are correct.
1. Set your AWS_PROFILE to one that has enough access to create the resources:
   ```shell
   export AWS_PROFILE=devopscoop_AdministratorAccess
   ```
1. Initialize the repo:
   ```shell
   tofu init
   ```
1. Apply the code to create the S3 bucket and DynamoDB:
   ```shell
   tofu apply
   ```
1. Against our better judgement, commit the terraform.tfstate* files to the repo. This is normally SUPER-FORBIDDEN! State files often have cleartext secrets in them, and we NEVER want to commit secrets to the repo. However, these particular files don't have any secrets in them:
   ```shell
   git add -f terraform.tfstate*
   git commit -m "Bootstrapping OpenTofu"
   ```

### configure-aws-credentials

https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services

If you are using a subtree, you probably already have a role with permissions to run your workflow, so you can probably skip this section.

While it seems like we should do this with Terraform, we have to do this in order for Terraform to have access to our AWS account, so actually, it just needs to be done manually...

1. Log into the AWS Console
1. Select your region.
1. If you already have an OIDCProvider named token.actions.githubusercontent.com, you'll need to enter its ARN as the OIDCProviderArn when you create the the stack. You can find the arn with this command:
   ```
   aws iam list-open-id-connect-providers
   ```
1. Go to CloudFormation
1. Click Create Stack.
1. Select:
   - Choose an existing template
   - Upload a template file
1. Choose the `configure-aws-credentials/configure-aws-credentials-latest.yml` file, then click Next.
1. Specify these details, then click Next. For example:
   - Stack name: github-actions-project1-dev (github-actions-${repo_name})
   - GitHubOrg: devopscoop
   - OIDCAudience: leave this as the default
   - OIDCProviderArn: arn:aws:iam::999999999999:oidc-provider/token.actions.githubusercontent.com
   - RepositoryName: project1-dev
1. Click Next, scroll to the bottom, check the "acknowledge" box, click Next again, scroll down again, then click Submit.
1. When it's done, click on the Resources tab, then click on the Role name.
1. Get the ARN of the role that was created, it's probably something like: `arn:aws:iam::999999999999:role/github-actions-project1-dev-Role-op9nZF6VBumT`

### cluster

Based on https://github.com/aws-ia/terraform-aws-eks-blueprints/tree/246f26025eb99477b4f0c64f6c0b6a9bbb6422c6/patterns/stateful

1. Create a branch of this repo - you don't want to commit to main directly, or it will run `tofu apply` without showing you the plan. Note, if you are following the "subtree" process, just use your existing branch:
   ```
   git checkout -b create_cluster
   ```
1. Add the role ARN from the configure-aws-credentials section to the `role-to-assume` in .github/workflows/opentofu.yml (or opentofy-cluster_name.yml).
1. Edit the `cluster/terraform.tfvars` file.
1. Commit your changes, but don't push yet.
   ```
   git add -A
   git commit -m "Creating the cluster"
   ```
1. Checkout a new branch that's pointed at origin/main, which should be empty at this point:
  ```
  git checkout -b github_actions origin/main
  ```
1. Add the GitHub Actions file, commit, push:
  ```
  git checkout create_cluster .github
  git add .github
  git commit -m "Adding GitHub Actions so we can do the rest of the changes via GitOps."
  git push origin github_actions
  ```
1. Create a PR, and merge the branch to main.
1. Checkout the create_cluster branch again:
   ```
   git checkout create_cluster
   ```
1. Push it, create a PR, and Opentofu should create a comment on the PR with the output of a `tofu plan`.
1. If it looks good, merge it to the default branch to create your cluster.
1. TODO: Sometimes the job fails. Running it again and it will probably work. We need to troubleshoot this by running it manually since the error doesn't show up in GitHub Actions output.
1. Go the the GitHub Action that ran after you merged to the main branch. Look under the "Run tofu apply" step, and scroll to the bottom to find the `aws eks update-kubeconfig` command. Run that command to generate your kubeconfig.

### examples

## Destroying a cluster

To destroy a cluster, add `-destroy` to the `tofu plan` and `tofu apply` lines in the `.github/workflows/opentofu.yml` file.

Once the cluster has been destroyed, open AWS Console, go to Cloudformation, and delete the github-actions-project1-dev stack.

The last thing to clean up is the bootstrap code that created the S3 bucket and DynamoDB. To destroy that, go to the bootstrap directory on your local laptop, and run:

```
tofu destroy
```

This will likely fail, because the bucket isn't empty. In the AWS Console, find your S3 buckets (search for your cluster name), and empty them, then run the `tofu destroy` again.
