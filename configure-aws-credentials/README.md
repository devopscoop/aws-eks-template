# Configuring OpenID Connect in Amazon Web Services

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
