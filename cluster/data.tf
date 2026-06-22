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
  # This automatically maps `AWSReservedSSO_*` roles to the appropriate
  # Kubernetes ClusterRoles.
  #
  # We are creating a Kubernetes Group named `cluster-viewers` for the
  # `readonly` and `viewonly` AWS roles, because the AWS SSO ARNs have a
  # dynamic suffix (ex. "AWSReservedSSO_ReadOnlyAccess_08377194032f7d67"), and
  # we need a stable name to use in the fluxcd-template git repo to perform a
  # special ClusterRoleBinding for them. They need binding, because the
  # `AmazonEKSViewPolicy` doesn't aggregate CRD view roles - see
  # https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles.
  # Essentially, without this bullshit, the `readonly` and `viewonly` roles
  # can't see any CRD objects (flux objects, cert-manager, Envoy httproutes,
  # etc.)
  sso_access_entries = merge(
    {
      for arn in data.aws_iam_roles.administratoraccess.arns : arn => {
        principal_arn     = arn
        kubernetes_groups = []
        policy_associations = {
          AmazonEKSClusterAdminPolicy = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    },
    {
      for arn in concat(
        tolist(data.aws_iam_roles.viewonly.arns),
        tolist(data.aws_iam_roles.readonly.arns),
        ) : arn => {
        principal_arn     = arn
        kubernetes_groups = ["cluster-viewers"]
        policy_associations = {
          AmazonEKSViewPolicy = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    },
  )
}
