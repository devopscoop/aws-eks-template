module "bootstrap" {
  source  = "trussworks/bootstrap/aws"
  version = "v7.0.0"

  account_alias        = var.account_alias

  # The default name is just "terraform-state-lock". If we have multiple clusters in a single AWS account, this causes a name collision.
  dynamodb_table_name  = "${var.account_alias}-terraform-state-lock"

  manage_account_alias = var.manage_account_alias
  region               = var.region
}
