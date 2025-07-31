# diff --color=always -w -y -W200 <(curl -sL https://raw.githubusercontent.com/lablabs/terraform-aws-eks-cert-manager/master/examples/basic/main.tf) cert-manager.tf | less -R

locals {
  cluster_issuers_values = yamlencode({
    "route53" : {
      "default" : {
        "region" : var.region
        "dnsZones" : [
          var.zone_name,
        ]
        "acme" : {
          "email" : var.admin_email
          "server" : "https://acme-v02.api.letsencrypt.org/directory"
        }
      }
    }
    "http" : {
      "default-http" : {
        "ingressClassName" : "nginx"
        "acme" : {
          "email" : var.admin_email
          "server" : "https://acme-v02.api.letsencrypt.org/directory"
        }
      }
    }
  })
}

module "cert_manager_helm" {
  source = "git::https://github.com/lablabs/terraform-aws-eks-cert-manager.git?ref=v2.0.0"

  cluster_identity_oidc_issuer     = module.eks.oidc_provider
  cluster_identity_oidc_issuer_arn = module.eks.oidc_provider_arn

  namespace = "cert-manager"

  cluster_issuer_enabled = true
  cluster_issuers_values = local.cluster_issuers_values

  helm_wait_for_jobs = true

  helm_chart_version = "1.15.3"
}
