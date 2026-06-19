# Finding AWS SSO roles so we can give them access to Kubernetes and KMS.

data "aws_iam_roles" "administratoraccess" {
  name_regex  = "^AWSReservedSSO_AdministratorAccess"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

data "aws_iam_roles" "viewonly" {
  name_regex  = "^AWSReservedSSO_ViewOnlyAccess"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

data "aws_iam_roles" "readonly" {
  name_regex  = "^AWSReservedSSO_ReadOnlyAccess"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

locals {
  # Map each discovered AWSReservedSSO role to its EKS cluster-access-policy.
  # Add a new entry here to grant another permission set access to the cluster;
  # OpenTofu discovers the concrete role ARNs (incl. the random suffix) at plan
  # time, so there's nothing to hardcode.
  sso_access_policies = {
    AmazonEKSClusterAdminPolicy = data.aws_iam_roles.administratoraccess.arns
    AmazonEKSViewPolicy = concat(
      tolist(data.aws_iam_roles.viewonly.arns),
      tolist(data.aws_iam_roles.readonly.arns),
    )
  }

  # Flatten {policy => [arns]} into one access entry per (policy, arn) pair.
  # EKS strips the IAM path from SSO role ARNs, so we strip it here too to avoid
  # a perpetual diff (arn:...:role/aws-reserved/sso.amazonaws.com/<region>/NAME
  # becomes arn:...:role/NAME).
  sso_access_entries = {
    for pair in flatten([
      for policy, arns in local.sso_access_policies : [
        for arn in arns : {
          arn    = replace(arn, "/:role/.*//", ":role/")
          policy = policy
        }
      ]
      ]) : pair.arn => {
      principal_arn = pair.arn
      policy_associations = {
        (pair.policy) = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/${pair.policy}"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
}
