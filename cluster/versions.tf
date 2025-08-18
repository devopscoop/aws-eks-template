# diff --color=always -w -y -W200 <(curl -sL https://raw.githubusercontent.com/aws-ia/terraform-aws-eks-blueprints/main/patterns/stateful/versions.tf) versions.tf | less -R

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    helm = {
      source = "hashicorp/helm"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }

  # Naming schemes based on https://github.com/trussworks/terraform-aws-bootstrap?tab=readme-ov-file#using-the-backend
  backend "s3" {

    # This is probably "${var.account_alias}-${var.bucket_purpose}-${var.region}"
    bucket = var.tf_bucket

    dynamodb_table = var.dynamodb_table
    encrypt        = "true"

    # This is probably "${cluster_name}/terraform.tfstate"
    key = var.backend_s3_key

    region = var.region
  }
}
