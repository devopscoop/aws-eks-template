# diff --color=always -w -y -W200 <(curl -sL https://raw.githubusercontent.com/lablabs/terraform-aws-eks-external-dns/refs/heads/main/examples/basic/main.tf) external-dns.tf | less -R

# module "addon_installation_disabled" {
#   source = "../../"
#
#   enabled = false
#
#   cluster_identity_oidc_issuer     = module.eks_cluster.eks_cluster_identity_oidc_issuer
#   cluster_identity_oidc_issuer_arn = module.eks_cluster.eks_cluster_identity_oidc_issuer_arn
# }

module "addon_installation_helm" {
  source = "git::https://github.com/lablabs/terraform-aws-eks-external-dns.git?ref=v2.1.1"

  enabled           = var.enable_route53
  argo_enabled      = false
  argo_helm_enabled = false

  cluster_identity_oidc_issuer     = module.eks.oidc_provider
  cluster_identity_oidc_issuer_arn = module.eks.oidc_provider_arn

  values = file("${path.module}/external-dns.values.yaml")

  helm_chart_version = "1.18.0"
  helm_wait          = true
  helm_repo_url      = "https://kubernetes-sigs.github.io/external-dns/"

  # Official chart recommends that we use the "external-dns" namespace: https://github.com/kubernetes-sigs/external-dns/tree/master/charts/external-dns
  namespace = "external-dns"

  # Can't set this in the values file, because it requires a Terraform variable.
  settings = {
    txtOwnerId : var.cluster_name
  }

}

# module "addon_installation_helm_pod_identity" {
#   source = "../../"
#
#   enabled           = true
#   argo_enabled      = false
#   argo_helm_enabled = false
#
#   cluster_name = module.eks_cluster.eks_cluster_id
#
#   irsa_role_create         = false
#   pod_identity_role_create = true
#
#   values = yamlencode({
#     # insert sample values here
#   })
# }
#
# # Please, see README.md and Argo Kubernetes deployment method for implications of using Kubernetes installation method
# module "addon_installation_argo_kubernetes" {
#   source = "../../"
#
#   enabled           = true
#   argo_enabled      = true
#   argo_helm_enabled = false
#
#   cluster_identity_oidc_issuer     = module.eks_cluster.eks_cluster_identity_oidc_issuer
#   cluster_identity_oidc_issuer_arn = module.eks_cluster.eks_cluster_identity_oidc_issuer_arn
#
#   values = yamlencode({
#     # insert sample values here
#   })
#
#   argo_sync_policy = {
#     automated   = {}
#     syncOptions = ["CreateNamespace=true"]
#   }
# }
#
# module "addon_installation_argo_helm" {
#   source = "../../"
#
#   enabled           = true
#   argo_enabled      = true
#   argo_helm_enabled = true
#
#   cluster_identity_oidc_issuer     = module.eks_cluster.eks_cluster_identity_oidc_issuer
#   cluster_identity_oidc_issuer_arn = module.eks_cluster.eks_cluster_identity_oidc_issuer_arn
#
#   values = yamlencode({
#     # insert sample values here
#   })
#
#   argo_sync_policy = {
#     automated   = {}
#     syncOptions = ["CreateNamespace=true"]
#   }
# }
