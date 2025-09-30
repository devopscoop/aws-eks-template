module "bootstrap" {
  source  = "trussworks/bootstrap/aws"
  version = "v7.0.0"

  # We're setting this to the EKS cluster name, not the account alias. This variable is used to create the bucket names, and we want separate buckets per cluster so that `tofu apply` and `tofu destroy` don't affect any other clusters in this account.
  account_alias = var.cluster_name

  # TODO: We should disable DynamoDB once this issue is resolved: https://github.com/trussworks/terraform-aws-bootstrap/issues/133
  # The default is "terraform-state-lock". If we have multiple clusters in an AWS account, this causes a name collision, so we're adding the cluster name as a prefix.
  dynamodb_table_name = "${var.cluster_name}-terraform-state-lock"

  # The alias should be assigned during AWS account creation, which is outside the scope of this repo.
  manage_account_alias = false

  region = var.region
}
