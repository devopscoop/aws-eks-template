# external-dns runs inside the cluster and is now installed via Flux
# (fluxcd-template: apps/external-dns). All that remains here is the AWS IAM role
# that external-dns's ServiceAccount assumes (IRSA) so it can manage Route53
# records.
#
# Wire the exported role ARN into the Flux external-dns values.yaml as the
# `eks.amazonaws.com/role-arn` annotation on the external-dns ServiceAccount.
# Only needed when external-dns uses the AWS/Route53 provider (the fluxcd-template
# default is Cloudflare, which authenticates with an API token instead); gated on
# enable_route53. The hosted-zone scope defaults to every zone in the account
# (module default) — pass external_dns_hosted_zone_arns to tighten it.

module "external_dns_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.2.1"

  count = var.enable_route53 ? 1 : 0

  name            = "external-dns"
  use_name_prefix = false

  attach_external_dns_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns"]
    }
  }

  depends_on = [module.eks]
}

output "external_dns_role_arn" {
  description = "IRSA role ARN for external-dns's ServiceAccount. Set this as the eks.amazonaws.com/role-arn annotation on the external-dns ServiceAccount in fluxcd-template (AWS/Route53 provider only)."
  value       = var.enable_route53 ? module.external_dns_irsa[0].arn : null
}
