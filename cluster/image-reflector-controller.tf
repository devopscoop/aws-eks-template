module "image_reflector_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.0"
  count   = var.enable_image_reflector_controller ? 1 : 0

  name            = "flux-image-reflector-controller"
  use_name_prefix = false

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["flux-system:image-reflector-controller"]
    }
  }

  policies = {
    ecr_read = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  }
}

output "image_reflector_controller_role_arn" {
  description = "IAM role ARN for the Flux image-reflector-controller"
  value       = one(module.image_reflector_controller_irsa[*].arn)
}
