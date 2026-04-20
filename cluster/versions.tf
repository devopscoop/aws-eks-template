# diff --color=always -w -y -W200 <(curl -sL https://raw.githubusercontent.com/aws-ia/terraform-aws-eks-blueprints/main/patterns/stateful/versions.tf) versions.tf | less -R

terraform {
  required_version = "1.11.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.40.0"
    }
    helm = {
      source = "hashicorp/helm"

      # TODO: Stuck at 2.17.0 until https://github.com/lablabs/terraform-aws-eks-cert-manager/issues/29 is fixed.
      version = "2.17.0"

    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.0.1"
    }
  }

  # Naming schemes based on https://github.com/trussworks/terraform-aws-bootstrap?tab=readme-ov-file#using-the-backend
  backend "s3" {
    bucket = "${var.bucket}"
    use_lockfile = "true"
    encrypt      = "true"
    key          = "${var.cluster_name}/terraform.tfstate"
    region       = var.region
  }
}
