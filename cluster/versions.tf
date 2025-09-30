# diff --color=always -w -y -W200 <(curl -sL https://raw.githubusercontent.com/aws-ia/terraform-aws-eks-blueprints/main/patterns/stateful/versions.tf) versions.tf | less -R

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    helm = {
      source = "hashicorp/helm"

      # TODO: Stuck at 2.17.0 until https://github.com/lablabs/terraform-aws-eks-cert-manager/issues/29 is fixed.
      version = "2.17.0"

    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }

  # Naming schemes based on https://github.com/trussworks/terraform-aws-bootstrap?tab=readme-ov-file#using-the-backend
  backend "s3" {
    bucket = "${var.cluster_name}-tf-state-${var.region}"

    # TODO: We should disable DynamoDB once this issue is resolved: https://github.com/trussworks/terraform-aws-bootstrap/issues/133
    dynamodb_table = "${var.cluster_name}-terraform-state-lock"

    use_lockfile = "true"
    encrypt      = "true"
    key          = "${var.cluster_name}/terraform.tfstate"
    region       = var.region
  }
}
