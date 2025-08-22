resource "aws_route53_zone" "primary" {
  count = var.enable_route53 ? 1 : 0
  name  = var.zone_name
}
