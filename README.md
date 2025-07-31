# README

Based on https://github.com/aws-ia/terraform-aws-eks-blueprints/tree/246f26025eb99477b4f0c64f6c0b6a9bbb6422c6/patterns/stateful

This repo sets up our AWS EKS Kubernetes cluster

1. [Bootstrap](bootstrap/README.md) the repo to create S3 buckets and DynamoDB for OpenTofu.
1. [Configure AWS credentials](configure-aws-credentials/README.md) to allow GitHub Actions to perform tasks in our AWS account.
1. Create a `.tfvars` file like this:
  ```
  admin_email    = "admin@devops.coop"
  backend_s3_key = "cluster-tf/dev/terraform.tfstate"
  cluster_name   = "dev"
  github_repos   = ["repo:devopscoop/dev-k8s:*", ]
  region         = "us-east-2"
  tags_git_repo  = "github.com/devopscoop/cluster-tf"
  tf_bucket      = "devopscoop-cluster-tf-state-us-east-2"
  zone_name      = "dev.devops.coop"
  ```
1. Optionally test locally:
  ```
  tofu init -var-file=dev.tfvars
  tofu plan -var-file=dev.tfvars
  ```
1. Create a pull request.
1. Review the OpenTofu plan in the PR.
1. Merge to apply the change.
1. After OpenTofu finishes, uncomment this `github-actions` block in main.tf and create another PR.

## Destroy

To destroy a cluster, add `-destroy` to the `tofu plan` and `tofu apply` lines in the `.github/workflows/opentofu.yml` file.
