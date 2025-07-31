# Based on:
# https://registry.terraform.io/modules/terraform-aws-modules/s3-bucket/aws/latest
# https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
# https://docs.aws.amazon.com/eks/latest/userguide/associate-service-account-role.html

module "lolrus" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "4.1.2"

  bucket = "lolrus-${var.cluster_name}-devopscoop-${var.region}"
  acl    = "private"

  control_object_ownership = true
  object_ownership         = "ObjectWriter"

  versioning = {
    enabled = true
  }
}

data "aws_iam_policy_document" "lolrus_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values = [
        "sts.amazonaws.com",
      ]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values = [
        "system:serviceaccount:lolrus:lolrus-app",
      ]
    }
    principals {
      identifiers = [module.eks.oidc_provider_arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "lolrus" {
  assume_role_policy = data.aws_iam_policy_document.lolrus_assume.json
  name               = "lolrus"
}

data "aws_iam_policy_document" "lolrus" {
  statement {
    effect  = "Allow"
    actions = ["s3:Get*", "s3:List*"]
    resources = [
      module.lolrus.s3_bucket_arn,
      "${module.lolrus.s3_bucket_arn}/*"
    ]
  }
}

resource "aws_iam_policy" "lolrus" {
  name   = "lolrus"
  policy = data.aws_iam_policy_document.lolrus.json
}

resource "aws_iam_role_policy_attachment" "lolrus" {
  role       = aws_iam_role.lolrus.name
  policy_arn = aws_iam_policy.lolrus.arn
}
