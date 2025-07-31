# Based on:
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment

data "aws_iam_policy_document" "helmfile_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"]
    }

    actions = [
      "sts:AssumeRoleWithWebIdentity",
    ]

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values = [
        "sts.amazonaws.com",
      ]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.github_repos
    }
  }
}

resource "aws_iam_role" "helmfile" {
  name               = "github-actions-${var.cluster_name}-helm"
  assume_role_policy = data.aws_iam_policy_document.helmfile_assume.json
}

data "aws_iam_policy_document" "helmfile" {
  statement {
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:${var.region}:${local.account_id}:cluster/${var.cluster_name}"]
  }
}

resource "aws_iam_policy" "helmfile" {
  name   = "github-actions-${var.cluster_name}-helm"
  policy = data.aws_iam_policy_document.helmfile.json
}

resource "aws_iam_role_policy_attachment" "helmfile" {
  role       = aws_iam_role.helmfile.name
  policy_arn = aws_iam_policy.helmfile.arn
}
