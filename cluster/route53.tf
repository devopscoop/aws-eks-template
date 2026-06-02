resource "aws_route53_zone" "primary" {
  count = (var.enable_route53 && var.create_route53_zone) ? 1 : 0
  name  = var.zone_name
}

data "aws_route53_zone" "primary" {
  count = (var.enable_route53 && !var.create_route53_zone) ? 1 : 0
  name  = var.zone_name
}

locals {
  hosted_zone_arn = var.enable_route53 ? (
    var.create_route53_zone ? aws_route53_zone.primary[0].arn : data.aws_route53_zone.primary[0].arn
  ) : null
}
