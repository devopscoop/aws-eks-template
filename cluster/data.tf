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
  # The ARNs are passed through as-is, including the SSO IAM path
  # (arn:...:role/aws-reserved/sso.amazonaws.com/<region>/NAME). EKS validates
  # that the principal exists, so the full path is required — stripping it
  # yields an "invalid principal" error.
  sso_access_entries = {
    for pair in flatten([
      for policy, arns in local.sso_access_policies : [
        for arn in arns : {
          arn    = arn
          policy = policy
        }
      ]
      ]) : pair.arn => {
      principal_arn = pair.arn
      # In addition to the AWS managed policy, bind the SSO view roles to a
      # Kubernetes group so RBAC can extend their access. AmazonEKSViewPolicy is
      # a frozen ruleset that does NOT aggregate operator-provided ClusterRoles,
      # so CRDs (Flux, cert-manager, etc.) are invisible to it. Binding this
      # group to the built-in `view` ClusterRole — which DOES aggregate
      # `aggregate-to-view` roles while still excluding Secrets — makes those
      # CRDs visible. The admin role needs no group (cluster-admin covers all).
      # The companion ClusterRoleBinding for `cluster-viewers` lives in the
      # fluxcd-template repo (flux/flux-system/cluster-viewers-rbac.yaml).
      kubernetes_groups = pair.policy == "AmazonEKSViewPolicy" ? ["cluster-viewers"] : []
      policy_associations = {
        (pair.policy) = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/${pair.policy}"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
}
