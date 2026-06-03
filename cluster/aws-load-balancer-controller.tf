module "aws_load_balancer_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.6.1"

  name            = "aws-load-balancer-controller"
  use_name_prefix = false

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  depends_on = [module.eks]
}

output "aws_load_balancer_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller ServiceAccount. Set this as the eks.amazonaws.com/role-arn annotation in fluxcd-template (apps/aws-load-balancer-controller)."
  value       = module.aws_load_balancer_controller_irsa.arn
}
