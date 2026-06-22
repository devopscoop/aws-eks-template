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
  # One EKS access entry per discovered AWSReservedSSO role, keyed by ARN. ARNs
  # are discovered at plan time, so there's nothing to hardcode; to grant
  # another permission set access, merge in another comprehension below.
  #
  # ARNs are passed through as-is, including the SSO IAM path
  # (arn:...:role/aws-reserved/sso.amazonaws.com/<region>/NAME). EKS validates
  # that the principal exists, so the full path is required — stripping it
  # yields an "invalid principal" error.
  #
  # The view roles also join `cluster-viewers`, which fluxcd-template
  # (apps/cluster-viewers/clusterrolebinding.yaml) binds to the built-in `view`
  # ClusterRole. Unlike AmazonEKSViewPolicy, `view` aggregates CRD viewers
  # (Flux, cert-manager, ...) while still excluding Secrets. We keep the managed
  # policy as a baseline so view access survives until Flux applies that binding.
  #
  # A fixed group name (not the ARNs) is the stable contract with that binding:
  # the ARNs are dynamic and the binding is static YAML in a separate repo that
  # can't interpolate them (Terraform can't manage RBAC here — no in-cluster
  # provider, see main.tf).
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
