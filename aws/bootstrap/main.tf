module "bootstrap" {
  source  = "trussworks/bootstrap/aws"
  version = "v7.0.0"

  account_alias        = var.account_alias
  manage_account_alias = var.manage_account_alias
  region               = var.region
}
