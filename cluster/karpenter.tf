# AWS-side resources for Karpenter, the node autoscaler. The controller itself
# is a Helm release reconciled by Flux from fluxcd-template (apps/karpenter);
# per this repo's pattern, only the IAM/IRSA pieces live here and the role ARN
# gets pasted into the ServiceAccount annotation over there.
#
# The other IRSA roles in this repo use
# terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts, but
# that module dropped its Karpenter policy in v6 in favor of this sub-module
# of the EKS module (pinned to the same version as module.eks). The sub-module
# also creates everything else Karpenter needs on the AWS side:
#
#   - the controller IAM role and its (versioned, Karpenter-1.x) policy
#   - the node IAM role that Karpenter-launched instances run as
#   - the EKS access entry that lets those nodes join the cluster
#   - the SQS queue + EventBridge rules for spot interruption / rebalance /
#     scheduled-maintenance handling
#
# https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/21.24.2/submodules/karpenter

# From v21 the sub-module only writes an EKS Pod Identity trust policy
# (pods.eks.amazonaws.com) for the controller role; the IRSA variables were
# removed. This cluster uses IRSA for every controller (see AGENTS.md), and
# the fluxcd-template side already ships the eks.amazonaws.com/role-arn
# annotation, so we override the trust policy with the classic OIDC-federated
# one.
data "aws_iam_policy_document" "karpenter_controller_assume_role" {
  # The sid must remain "PodIdentity": documents passed through
  # iam_role_override_assume_policy_documents override base statements by
  # matching sid, and "PodIdentity" is the sid of the sub-module's built-in
  # pod-identity statement. Any other sid would append this statement instead
  # of replacing that one.
  statement {
    sid     = "PodIdentity"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    # Bind the role to exactly the karpenter ServiceAccount in kube-system —
    # the namespace the getting-started guide installs into
    # (KARPENTER_NAMESPACE="kube-system") and where fluxcd-template deploys
    # the chart. The ServiceAccount name defaults to the release name.
    # https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:karpenter"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.24.2"

  cluster_name = module.eks.cluster_name

  # The role name is what the eks.amazonaws.com/role-arn annotation in
  # fluxcd-template (apps/karpenter/values.yaml) points at; keep them in sync.
  # The module default is "KarpenterController" with a name prefix.
  iam_role_name            = "karpenter"
  iam_role_use_name_prefix = false

  iam_role_override_assume_policy_documents = [
    data.aws_iam_policy_document.karpenter_controller_assume_role.json
  ]

  # IRSA, not Pod Identity — see the comment on the trust policy above.
  create_pod_identity_association = false

  # The node role's CNI policy must match the cluster's IP family: main.tf
  # sets ip_family = "ipv6", and its create_cni_ipv6_iam_policy = true creates
  # the account-level AmazonEKS_CNI_IPv6_Policy that this setting attaches.
  cluster_ip_family = "ipv6"

  # Predictable, cluster-agnostic name for EC2NodeClass spec.role references
  # in fluxcd-template, consistent with the static names used by the other
  # roles in this repo. The module default is "Karpenter-<cluster_name>".
  node_iam_role_name            = "karpenter-node"
  node_iam_role_use_name_prefix = false

  # "<cluster>-karpenter-interruption" so the queue is recognizable in the
  # console as Karpenter's interruption queue rather than an anonymous
  # cluster-named queue (the module default is "Karpenter-<cluster>", which
  # buries what the queue is *for*). This name is what
  # apps/karpenter/values.yaml sets for settings.interruptionQueue — keep them
  # in sync; the cluster-name prefix is rewritten by both repos' placeholder
  # replacement on fork. The queue age alarm in cloudwatch-alarms.tf
  # references it through module.karpenter.queue_name, so it follows along.
  queue_name = "${module.eks.cluster_name}-karpenter-interruption"
}

# EC2 refuses spot requests until the account-level AWSServiceRoleForEC2Spot
# service-linked role exists, so this is a prerequisite for "spot" in a
# NodePool's karpenter.sh/capacity-type requirements (fluxcd-template,
# apps/karpenter-custom-resources). The getting-started guide creates it
# imperatively (aws iam create-service-linked-role --aws-service-name
# spot.amazonaws.com); manage it here instead so forks get it without a manual
# step.
#
# The gate exists because there is exactly one such role per account, and any
# prior spot use — an ASG, the console, another cluster — creates it
# implicitly. A plan can't see that (name collisions only surface at create),
# so an unconditional resource would plan green and then fail the apply on
# main with InvalidInput; since cluster/ is applied by CI only, the tofu
# import that recovers from this isn't reachable without breaking that rule.
# Forks in an account that already has the role set
# create_spot_service_linked_role = false in terraform.tfvars and skip both
# the create and — equally important in a shared account — the destroy.
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/service-linked-roles-spot-instance-requests.html
resource "aws_iam_service_linked_role" "spot" {
  count = var.create_spot_service_linked_role ? 1 : 0

  aws_service_name = "spot.amazonaws.com"
}

output "karpenter_role_arn" {
  description = "IRSA role ARN for the Karpenter controller ServiceAccount. Set this as the eks.amazonaws.com/role-arn annotation in fluxcd-template (apps/karpenter/values.yaml, eks marker block)."
  value       = module.karpenter.iam_role_arn
}

output "karpenter_node_iam_role_name" {
  description = "IAM role name for Karpenter-launched nodes. Set this as spec.role in EC2NodeClass resources in fluxcd-template (apps/karpenter-custom-resources)."
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_interruption_queue_name" {
  description = "SQS queue name for interruption handling. Set this as settings.interruptionQueue in fluxcd-template (apps/karpenter/values.yaml)."
  value       = module.karpenter.queue_name
}
