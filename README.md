# aws-eks-template

This repo can be used to build a production-ready AWS EKS Kubernetes cluster. It can either be forked, or included in a monorepo à la carte with `git subtree`. There are four directories in this repo that should be processed in order:

1. **bootstrap**: creates an encrypted AWS S3 bucket for OpenTofu's state files, and a DynamoDB table for state locking.
1. **configure-aws-credentials**: creates an AWS Role that will be used by the CI/CD pipeline.
1. **cluster**: is executed by the CI/CD pipeline to create the cluster.
1. **examples**: has additional code to build more AWS resources if you need them.

## Creating a cluster

> **WARNING**
> Don't `git push` any code unless there is an instruction to do so. If you push code too early, you will either get CI/CD pipeline errors, or you will accidentally build a misconfigured cluster.

### bootstrap

Based on:

- <https://github.com/trussworks/terraform-aws-bootstrap>
- <https://opentofu.org/docs/language/settings/backends/configuration/>

Process:

1. Change directory to `bootstrap`.
1. Update the values in the `terraform.tfvars` file.
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

While it seems like we should do this with Terraform, we have to do this in order for Terraform to have access to our AWS account, so actually, it just needs to be done manually...


1. Log into the AWS Console
1. Select your region.
1. If you already have an OIDCProvider named token.actions.githubusercontent.com, you'll need to enter its ARN as the OIDCProviderArn when you create the the stack. You can find the arn with this command:
   ```
   aws iam list-open-id-connect-providers
   ```
1. Go to CloudFormation
1. Click Create Stack, and select:
   - Choose an existing template
   - Upload a template file
1. Choose the `configure-aws-credentials/configure-aws-credentials-latest.yml` file, then click Next.
1. Specify these details, then click Next. For example:
   - Stack name: github-actions-project1-dev (github-actions-${repo_name})
   - GitHubOrg: devopscoop
   - OIDCAudience: leave this as the default
   - OIDCProviderArn: arn:aws:iam::999999999999:oidc-provider/token.actions.githubusercontent.com
   - RepositoryName: project1-dev
1. Click Next, check the box, then click Submit.
1. When it's done, click on the Resources tab, then click on the Role name.
1. Get the ARN of the role that was created, it's probably something like: `arn:aws:iam::999999999999:role/github-actions-project1-dev-Role-op9nZF6VBumT`

### cluster

Based on https://github.com/aws-ia/terraform-aws-eks-blueprints/tree/246f26025eb99477b4f0c64f6c0b6a9bbb6422c6/patterns/stateful

1. Create a branch of this repo - you don't want to commit to main directly, or it will run `tofu apply` without showing you the plan:
   ```
   git checkout -b create_cluster
   ```
1. Add the role ARN from the configure-aws-credentials section to the `role-to-assume` in .github/workflows/opentofu.yml.
1. Change directory to `cluster`.
1. Edit the `terraform.tfvars` file.
1. Optionally test locally:
   ```
   tofu init
   tofu plan
   ```
1. Create a PR, and Opentofu should create a comment on the PR with the output of a `tofu plan`.
1. If it looks good, merge it to the default branch to create your cluster.
1. After OpenTofu finishes, uncomment this `github-actions` block in main.tf and create another PR.

### examples

## Destroying a cluster

To destroy a cluster, add `-destroy` to the `tofu plan` and `tofu apply` lines in the `.github/workflows/opentofu.yml` file.
