# diff --color=always -w -y -W200 <(curl -sL https://raw.githubusercontent.com/lablabs/terraform-aws-eks-external-dns/master/examples/basic/main.tf) external-dns.tf | less -R

resource "aws_route53_zone" "primary" {
  name = var.zone_name
}

module "external_dns_helm" {
  source = "git::https://github.com/lablabs/terraform-aws-eks-external-dns.git?ref=v1.2.0"

  cluster_identity_oidc_issuer     = module.eks.oidc_provider
  cluster_identity_oidc_issuer_arn = module.eks.oidc_provider_arn

  namespace = "external-dns"

  values = file("${path.module}/external-dns.values.yaml")

  settings = {
    txtOwnerId : var.cluster_name
  }

  helm_wait = true

  helm_repo_url      = "https://kubernetes-sigs.github.io/external-dns/"
  helm_chart_version = "1.14.5"

}
