# Configuring OpenID Connect in Amazon Web Services

https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services

## Creating and managing an IAM OIDC identity provider (AWS CLI)

https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services

While it seems like we should do this with Terraform, we have to do this in order for Terraform to have access to our AWS account, so actually, it just needs to be done manually...

1. Log into the AWS Console
1. Go to CloudFormation
1. Click Create Stack, and select:
  - Choose an existing template
  - Upload a template file
1. Choose the configure-aws-credentials-latest.yml file in this directory, then click Next.
1. Specify these details, then click Next:
  - Stack name: github-actions-cluster-tf
  - GitHubOrg: devopscoop
  - RepositoryName: cluster-tf
1. Next, next, check the box, Submit.
1. Get the ARN of the role that was created, it's probably something like: arn:aws:iam::471112796903:role/github-actions-cluster-tf-Role-op9nZF6VBumT
1. Add it to the `role-to-assume` in .github/workflows/opentofu.yml
