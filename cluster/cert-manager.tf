module "cert_manager_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.2.1"

  count = var.enable_route53 ? 1 : 0

  name            = "cert-manager"
  use_name_prefix = false

  attach_cert_manager_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["cert-manager:cert-manager"]
    }
  }

  depends_on = [module.eks]
}

output "cert_manager_role_arn" {
  description = "IRSA role ARN for cert-manager's ServiceAccount. Set this as the eks.amazonaws.com/role-arn annotation on the cert-manager ServiceAccount in fluxcd-template."
  value       = var.enable_route53 ? module.cert_manager_irsa[0].arn : null
}
