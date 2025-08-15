# diff --color=always -w -y -W200 <(curl -sL https://raw.githubusercontent.com/aws-ia/terraform-aws-eks-blueprints/main/patterns/stateful/outputs.tf) outputs.tf | less -R

output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"

  # Why all the options?
  #
  # --alias: this will default to the cluster arn, which is not very
  # user-friendly, and also won’t work if we want to create multiple contexts
  # with different roles for the same cluster.
  #
  # --kubeconfig: We want the ability to use the KUBECONFIG env var to select
  # configs, so we need specify this so it doesn’t write the config into our
  # default ~/.kube/config file.
  #
  # --name: this is required.
  #
  # --profile: this is good practice. Many of us have access to multiple AWS
  # account/role combinations. If we don’t specify a profile when creating the
  # kubeconfig, the kubeconfig may be created with the wrong AWS profile, or
  # with no profile if we’ve used saml2aws shell or something similar to
  # authenticate. If we don’t set profile, we will waste time troubleshooting
  # credential/auth issues in the future.
  #
  # --region: this is required.
  #
  # --user-alias: by default this is set to the cluster arn. This will cause a
  # problem if we want to configure multiple contexts with different AWS roles
  # for a cluster. For example, if I want to have one context that connects
  # using the DevOps role, and another one that connects using the Admin role,
  # and I don’t specify a --user-alias, then the second aws eks
  # update-kubeconfig command will overwrite the Kubernetes context user with
  # the last role I specify.
  #
  # And the naming scheme of ${cluster_name}_${region}_${AWS_PROFILE} is
  # intended to make autocompletion as simple as possible, ie. k config
  # use-context cluster_name<TAB>. You can technically have EKS clusters with
  # the same name in different regions, so we should keep region in there, and
  # if we have a cluster that we want to connect to with different roles, we
  # should keep the role on there. If you don’t use autocompletion, this naming
  # scheme is pretty long and tedious. If we all agree to have globally unique
  # cluster names, and use a single, minimally-permissive role to connect to
  # all clusters, then we could perhaps shorten the naming scheme to
  # ${cluster_name}.
  value = <<-EOT
    aws eks update-kubeconfig \
      --alias ${module.eks.cluster_name}_${local.region}_$${AWS_PROFILE} \
      --kubeconfig ~/.kube/${module.eks.cluster_name}_${local.region}_$${AWS_PROFILE} \
      --name ${module.eks.cluster_name} \
      --profile $${AWS_PROFILE} \
      --region ${local.region} \
      --user-alias ${module.eks.cluster_name}_${local.region}_$${AWS_PROFILE}
  EOT

}
