module "sops" {
  source  = "terraform-aws-modules/kms/aws"
  version = "3.1.0"

  key_users = flatten([
    tolist(data.aws_iam_roles.administratoraccess.arns),
    aws_iam_role.helmfile.arn
  ])

  aliases = ["sops"]
}
