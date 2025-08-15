# aws-eks-template

This repo can be used to build a production-ready AWS EKS Kubernetes cluster. It can either be forked, or included in a monorepo à la carte with `git subtree`. There are four directories in this repo that should be processed in order:

1. **bootstrap**: creates an encrypted AWS S3 bucket for OpenTofu's state files, and a DynamoDB table for state locking.
1. **configure-aws-credentials**: creates an AWS Role that will be used by the CI/CD pipeline.
1. **cluster**: is executed by the CI/CD pipeline to create the cluster.
1. **examples**: has additional code to build more AWS resources if you need them.

## Creating a cluster

### bootstrap

Based on:

- <https://github.com/trussworks/terraform-aws-bootstrap>
- <https://opentofu.org/docs/language/settings/backends/configuration/>

Process:

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
   git push
   ```
### configure-aws-credentials

https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services

While it seems like we should do this with Terraform, we have to do this in order for Terraform to have access to our AWS account, so actually, it just needs to be done manually...

If you already have an OIDCProvider named token.actions.githubusercontent.com, you'll need to enter its ARN as the OIDCProviderArn when you create the the stack. You can find the arn with this command:

```
aws iam list-open-id-connect-providers
```

1. Log into the AWS Console
1. Go to CloudFormation
1. Click Create Stack, and select:
   - Choose an existing template
   - Upload a template file
1. Choose the configure-aws-credentials-latest.yml file in this directory, then click Next.
1. Specify these details, then click Next. For example:
   - Stack name: github-actions-project1-dev (github-actions-${repo_name})
   - GitHubOrg: devopscoop
   - RepositoryName: project1-dev
   - OIDCProviderArn: arn:aws:iam::999999999999:oidc-provider/token.actions.githubusercontent.com
1. Next, next, check the box, Submit.
1. Get the ARN of the role that was created, it's probably something like: arn:aws:iam::999999999999:role/github-actions-project1-dev-Role-op9nZF6VBumT
1. Create a branch of this repo, and add the role ARN to the `role-to-assume` in .github/workflows/opentofu.yml.
1. Create a PR, and Opentofu should create a comment on the PR with the output of a `tofu plan`.
1. If it looks good, merge it to the default branch to create your cluster.

### cluster

Based on https://github.com/aws-ia/terraform-aws-eks-blueprints/tree/246f26025eb99477b4f0c64f6c0b6a9bbb6422c6/patterns/stateful

1. [Bootstrap](bootstrap/README.md) the repo to create S3 buckets and DynamoDB for OpenTofu.
1. [Configure AWS credentials](configure-aws-credentials/README.md) to allow GitHub Actions to perform tasks in our AWS account.
1. Create a `terraform.tfvars` file like this:
   ```
   admin_email    = "project1@devops.coop"
   backend_s3_key = "project1-dev/terraform.tfstate"
   cluster_name   = "project1-dev"
   github_repos   = ["repo:devopscoop/project1-dev:*", ]
   region         = "us-east-2"
   tags_git_repo  = "github.com/devopscoop/project1-dev"
   tf_bucket      = "devopscoop-project1-dev-tf-state-us-east-2"
   vpc_cidr       = "10.0.0.0/16"
   zone_name      = "project1-dev.devops.coop"
   ```
1. Optionally test locally:
   ```
   tofu init
   tofu plan
   ```
1. Create a pull request.
1. Review the OpenTofu plan in the PR.
1. Merge to apply the change.
1. After OpenTofu finishes, uncomment this `github-actions` block in main.tf and create another PR.

### examples

## Destroying a cluster

To destroy a cluster, add `-destroy` to the `tofu plan` and `tofu apply` lines in the `.github/workflows/opentofu.yml` file.
