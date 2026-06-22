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
  # Map each discovered AWSReservedSSO role to its EKS cluster-access-policy and
  # any extra Kubernetes RBAC groups. ARNs are discovered at plan time, so
  # there's nothing to hardcode; add an entry here to grant another permission
  # set access.
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
  sso_access_policies = {
    AmazonEKSClusterAdminPolicy = {
      arns   = data.aws_iam_roles.administratoraccess.arns
      groups = []
    }
    AmazonEKSViewPolicy = {
      arns = concat(
        tolist(data.aws_iam_roles.viewonly.arns),
        tolist(data.aws_iam_roles.readonly.arns),
      )
      groups = ["cluster-viewers"]
    }
  }

  # Flatten {policy => {arns, groups}} into one access entry per (policy, arn)
  # pair. The ARNs are passed through as-is, including the SSO IAM path
  # (arn:...:role/aws-reserved/sso.amazonaws.com/<region>/NAME). EKS validates
  # that the principal exists, so the full path is required — stripping it
  # yields an "invalid principal" error.
  sso_access_entries = {
    for pair in flatten([
      for policy, cfg in local.sso_access_policies : [
        for arn in cfg.arns : {
          arn    = arn
          policy = policy
          groups = cfg.groups
        }
      ]
      ]) : pair.arn => {
      principal_arn     = pair.arn
      kubernetes_groups = pair.groups
      policy_associations = {
        (pair.policy) = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/${pair.policy}"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
}
