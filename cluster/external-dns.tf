module "external_dns_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.0"

  count = var.enable_route53 ? 1 : 0

  name            = "external-dns"
  use_name_prefix = false

  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = compact([local.hosted_zone_arn])

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns"]
    }
  }
}

output "external_dns_role_arn" {
  description = "IRSA role ARN for external-dns's ServiceAccount. Set this as the eks.amazonaws.com/role-arn annotation on the external-dns ServiceAccount in fluxcd-template (AWS/Route53 provider only)."
  value       = var.enable_route53 ? module.external_dns_irsa[0].arn : null
}
