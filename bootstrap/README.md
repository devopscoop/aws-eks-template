# Bootstrap

## Overview

Based on:

- <https://github.com/trussworks/terraform-aws-bootstrap>
- <https://opentofu.org/docs/language/settings/backends/configuration/>

OpenTofu needs a place to store its state files. In an AWS environment, we need an encrypted S3 bucket to store the files, and we use DynamoDB to control state locking.

This is a one-time setup process that needs to be done once per AWS account. This directory has everything we need to set it up.

## Process

1. Update the values in the terraform.tfvars file.
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

## Updating

1. Delete the `.terraform.lock.hcl` file.
1. Find the latest version of trussworks/terraform-aws-bootstrap (see link at the top of this file)
1. Update the `version` in `main.tf`.
1. Pull the latest copy of the `variables.tf`:
   ```shell
   curl -O https://raw.githubusercontent.com/trussworks/terraform-aws-bootstrap/refs/heads/main/variables.tf
   ```
1. Generate a new `.terraform.lock.hcl` file:
   ```shell
   tofu init -upgrade
   ```
1. If the `variables.tf` file has any changes, make sure you update your `terraform.tfvars`.
1. Apply the updated code:
   ```shell
   tofu apply
   ```
1. Commit and push your changes:
   ```shell
   git add .
   git add -f terraform.tfstate*
   git commit -m "Updating the bootstrapping code"
   git push
   ```
