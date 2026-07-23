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
  hosted_zone_id = var.enable_route53 ? (
    var.create_route53_zone ? aws_route53_zone.primary[0].zone_id : data.aws_route53_zone.primary[0].zone_id
  ) : null
}

################################################################################
# DNS query logging
#
# Route 53 delivers public-zone query logs only to CloudWatch Logs log groups
# in us-east-1 (Route 53 is a global service homed there), so the log group and
# the CloudWatch Logs resource policy that lets Route 53 write to it use an
# aliased us-east-1 provider regardless of var.region. Query logging supports
# SOC 2 (CC7.2, System Monitoring) and ISO/IEC 27001:2022 Annex A 8.15
# (Logging); 365 days of retention matches the EKS control-plane log retention
# (main.tf) and covers the 12-month SOC 2 Type II observation period.
#
# Route 53 allows a single query logging config per hosted zone. If
# create_route53_zone = false and the pre-existing zone already has query
# logging enabled, import that config into aws_route53_query_log.primary
# instead of letting this create a conflicting one.
################################################################################

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = local.tags
  }
}

resource "aws_cloudwatch_log_group" "route53_query_logs" {
  count    = var.enable_route53 ? 1 : 0
  provider = aws.us_east_1

  name              = "/aws/route53/${var.zone_name}"
  retention_in_days = 365
}

# CloudWatch Logs resource policy granting the Route 53 service permission to
# deliver query logs into /aws/route53/* log groups. The SourceAccount/
# SourceArn conditions scope delivery to this account's hosted zones and guard
# against the confused-deputy problem (same pattern as flow-logs.tf).
data "aws_iam_policy_document" "route53_query_logging" {
  count = var.enable_route53 ? 1 : 0

  statement {
    sid       = "Route53QueryLoggingWrite"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:log-group:/aws/route53/*"]

    principals {
      type        = "Service"
      identifiers = ["route53.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:route53:::hostedzone/*"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "route53_query_logging" {
  count    = var.enable_route53 ? 1 : 0
  provider = aws.us_east_1

  policy_name     = "${var.cluster_name}-route53-query-logging"
  policy_document = data.aws_iam_policy_document.route53_query_logging[0].json
}

resource "aws_route53_query_log" "primary" {
  count = var.enable_route53 ? 1 : 0

  zone_id                  = local.hosted_zone_id
  cloudwatch_log_group_arn = aws_cloudwatch_log_group.route53_query_logs[0].arn

  # Route 53 checks the resource policy when the query logging config is
  # created, so it must exist first.
  depends_on = [aws_cloudwatch_log_resource_policy.route53_query_logging]
}
