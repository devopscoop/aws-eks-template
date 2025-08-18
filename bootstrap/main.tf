module "bootstrap" {
  source  = "trussworks/bootstrap/aws"
  version = "v7.0.0"

  account_alias        = var.account_alias
  dynamodb_table_name  = var.dynamodb_table_name
  manage_account_alias = var.manage_account_alias
  region               = var.region
}
