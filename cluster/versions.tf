# diff --color=always -w -y -W200 <(curl -sL https://raw.githubusercontent.com/aws-ia/terraform-aws-eks-blueprints/main/patterns/stateful/versions.tf) versions.tf | less -R

terraform {
  required_version = "1.12.5"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.52.0 is the minimum required by terraform-aws-modules/eks 21.24.0.
      version = "6.62.0"
    }
  }

  # Naming schemes based on https://github.com/trussworks/terraform-aws-bootstrap?tab=readme-ov-file#using-the-backend
  backend "s3" {
    bucket       = var.bucket
    use_lockfile = "true"
    encrypt      = "true"
    key          = "${var.cluster_name}/terraform.tfstate"
    region       = var.region
  }
}
