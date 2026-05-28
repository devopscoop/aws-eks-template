# cert-manager runs inside the cluster and is now installed via Flux
# (fluxcd-template: apps/cert-manager + apps/cert-manager-custom-resources for the
# ClusterIssuer). All that remains here is the AWS IAM role that cert-manager's
# ServiceAccount assumes (IRSA) so its ACME DNS-01 solver can manage Route53
# records.
#
# Wire the exported role ARN into the Flux cert-manager values.yaml as the
# `eks.amazonaws.com/role-arn` annotation on the cert-manager ServiceAccount.
# Only needed when the ClusterIssuer uses the Route53 dns01 solver; gated on
# enable_route53 to match the rest of the Route53 wiring. The hosted-zone scope
# defaults to every zone in the account (module default) — pass
# cert_manager_hosted_zone_arns to tighten it.

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
