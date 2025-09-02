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
    bucket         = "${var.cluster_name}-tf-state-${var.region}"
    dynamodb_table = "${var.cluster_name}-terraform-state-lock"
    encrypt        = "true"
    key            = "${var.cluster_name}/terraform.tfstate"
    region         = var.region
  }
}
