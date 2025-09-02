# If you want to use more variables from the `variables.tf` file, you will need to add them to both the `main.tf` file, and this one.

# Set this to the EKS cluster name, not the account alias. This variable is used to create the bucket names, and we want separate buckets per cluster so that `tofu apply` and `tofu destroy` don't affect any other clusters in this account. 
account_alias = "project1-dev"

# Aliases should be assigned on AWS account creation, which is outside the scope of this code.
manage_account_alias = false

# This should be the same region as the one in cluster/terraform.tfvars.
region = "us-east-2"
