################################################################################
# EC2 CPU alarms: one per node group ASG; Maximum fires when any node runs hot.
################################################################################

# Supports SOC 2 CC7.2 (System Monitoring) and ISO/IEC 27001:2022 Annex A 8.16
# (Monitoring activities).
locals {
  # Alert when any node in the group sustains this CPU percentage or higher
  # for node_cpu_alarm_minutes.
  node_cpu_alarm_threshold = 90
  node_cpu_alarm_minutes   = 15
}

resource "aws_cloudwatch_metric_alarm" "node_cpu" {
  # One alarm per node group, on its ASG, which satisfies Vanta's per-instance
  # CPU check. Karpenter nodes have no ASG; fluxcd-template tags them
  # VantaNoAlert instead.
  for_each = module.eks.eks_managed_node_groups

  alarm_name        = "${local.name}-${each.key}-node-cpu-high"
  alarm_description = "CPUUtilization of a node in the ${each.key} EKS managed node group of cluster ${local.name} has been >= ${local.node_cpu_alarm_threshold}% for ${local.node_cpu_alarm_minutes} minutes."

  namespace   = "AWS/EC2"
  metric_name = "CPUUtilization"
  statistic   = "Maximum"

  dimensions = {
    # A managed node group always creates exactly one ASG.
    AutoScalingGroupName = one(each.value.node_group_autoscaling_group_names)
  }

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = local.node_cpu_alarm_threshold
  period              = 300
  evaluation_periods  = local.node_cpu_alarm_minutes * 60 / 300

  alarm_actions = [local.alarm_topic_arn]
  ok_actions    = [local.alarm_topic_arn]
}

################################################################################
# SQS queue age alarm on Karpenter's interruption queue (Vanta's SQS check).
################################################################################

# Supports SOC 2 CC7.2 (System Monitoring) and ISO/IEC 27001:2022 Annex A 8.16
# (Monitoring activities).
locals {
  # Karpenter's queue keeps messages for 300 s, so this must stay well below
  # that. A message this old means interruption handling is down.
  queue_age_alarm_threshold_seconds = 120
  queue_age_alarm_minutes           = 10
}

resource "aws_cloudwatch_metric_alarm" "karpenter_interruption_queue_age" {
  alarm_name        = "${local.name}-karpenter-interruption-queue-age"
  alarm_description = "ApproximateAgeOfOldestMessage of SQS queue ${local.name}-karpenter-interruption has been >= ${local.queue_age_alarm_threshold_seconds}s for ${local.queue_age_alarm_minutes} minutes. Karpenter is not consuming interruption events, so spot interruptions and scheduled maintenance will terminate nodes without graceful draining."

  namespace   = "AWS/SQS"
  metric_name = "ApproximateAgeOfOldestMessage"
  statistic   = "Maximum"

  dimensions = {
    QueueName = module.karpenter.queue_name
  }

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = local.queue_age_alarm_threshold_seconds
  period              = 300
  evaluation_periods  = local.queue_age_alarm_minutes * 60 / 300

  # An idle queue emits no metrics, and no data means no stuck messages.
  treat_missing_data = "notBreaching"

  alarm_actions = [local.alarm_topic_arn]
  ok_actions    = [local.alarm_topic_arn]
}

################################################################################
# NLB target-group health alarms, found through the LB controller's tags.
################################################################################

# Supports SOC 2 CC7.2 (System Monitoring) and ISO/IEC 27001:2022 Annex A 8.16
# (Monitoring activities).
locals {
  # Alert when a target group has had an unhealthy target (or no healthy
  # target) for this many consecutive minutes.
  nlb_health_alarm_minutes = 3
}

data "aws_resourcegroupstaggingapi_resources" "lbc_load_balancers" {
  resource_type_filters = ["elasticloadbalancing:loadbalancer"]

  tag_filter {
    key    = "elbv2.k8s.aws/cluster"
    values = [local.name]
  }

  # Key-only filter: any value. Restricts the match to Service-created NLBs;
  # the controller tags Ingress-created ALBs with ingress.k8s.aws/* instead,
  # and those have different metrics and failure modes.
  tag_filter {
    key = "service.k8s.aws/stack"
  }
}

data "aws_resourcegroupstaggingapi_resources" "lbc_target_groups" {
  resource_type_filters = ["elasticloadbalancing:targetgroup"]

  tag_filter {
    key    = "elbv2.k8s.aws/cluster"
    values = [local.name]
  }

  tag_filter {
    key = "service.k8s.aws/stack"
  }
}

locals {
  # <namespace>/<service> => the "net/<name>/<id>" CloudWatch LoadBalancer
  # dimension, cut from the LB ARN (…:loadbalancer/net/<name>/<id>). The
  # controller creates exactly one LB per Service stack.
  lbc_lb_dimension_by_stack = {
    for r in data.aws_resourcegroupstaggingapi_resources.lbc_load_balancers.resource_tag_mapping_list :
    r.tags["service.k8s.aws/stack"] => regex("loadbalancer/(.+)$", r.resource_arn)[0]
  }

  # <namespace>-<service>-<port> => dimensions, read at plan time: re-run the
  # apply after gateway Services are created or recreated. Target groups whose
  # LB is gone are skipped.
  lbc_target_group_dimensions = {
    for r in data.aws_resourcegroupstaggingapi_resources.lbc_target_groups.resource_tag_mapping_list :
    replace(join("-", split("/", r.tags["service.k8s.aws/resource"])), ":", "-") => {
      service       = r.tags["service.k8s.aws/resource"]
      load_balancer = local.lbc_lb_dimension_by_stack[r.tags["service.k8s.aws/stack"]]
      target_group  = regex("(targetgroup/.+)$", r.resource_arn)[0]
    } if contains(keys(local.lbc_lb_dimension_by_stack), r.tags["service.k8s.aws/stack"])
  }
}

resource "aws_cloudwatch_metric_alarm" "nlb_unhealthy_hosts" {
  for_each = local.lbc_target_group_dimensions

  alarm_name        = "${local.name}-nlb-${each.key}-unhealthy-hosts"
  alarm_description = "The NLB target group for ${each.value.service} on cluster ${local.name} has had an unhealthy target for ${local.nlb_health_alarm_minutes} minutes. Missing data also alarms: if the Service was recreated, the controller minted new LB/target-group names — re-run the apply pipeline to re-discover them."

  namespace   = "AWS/NetworkELB"
  metric_name = "UnHealthyHostCount"
  statistic   = "Maximum"

  dimensions = {
    LoadBalancer = each.value.load_balancer
    TargetGroup  = each.value.target_group
  }

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  period              = 60
  evaluation_periods  = local.nlb_health_alarm_minutes
  datapoints_to_alarm = local.nlb_health_alarm_minutes
  treat_missing_data  = "breaching"

  alarm_actions = [local.alarm_topic_arn]
  ok_actions    = [local.alarm_topic_arn]
}

# UnHealthyHostCount alone misses the zero-registered-targets case (0 targets
# => 0 unhealthy), so also require at least one healthy target.
resource "aws_cloudwatch_metric_alarm" "nlb_no_healthy_hosts" {
  for_each = local.lbc_target_group_dimensions

  alarm_name        = "${local.name}-nlb-${each.key}-no-healthy-hosts"
  alarm_description = "The NLB target group for ${each.value.service} on cluster ${local.name} has had no healthy targets for ${local.nlb_health_alarm_minutes} minutes — the gateway is down from AWS's perspective. Missing data also alarms: if the Service was recreated, the controller minted new LB/target-group names — re-run the apply pipeline to re-discover them."

  namespace   = "AWS/NetworkELB"
  metric_name = "HealthyHostCount"
  statistic   = "Minimum"

  dimensions = {
    LoadBalancer = each.value.load_balancer
    TargetGroup  = each.value.target_group
  }

  comparison_operator = "LessThanThreshold"
  threshold           = 1
  period              = 60
  evaluation_periods  = local.nlb_health_alarm_minutes
  datapoints_to_alarm = local.nlb_health_alarm_minutes
  treat_missing_data  = "breaching"

  alarm_actions = [local.alarm_topic_arn]
  ok_actions    = [local.alarm_topic_arn]
}

################################################################################
# Alarm notifications: alarm_topic_arn, else a topic for alarm_email_addresses.
################################################################################

locals {
  # Nothing to create when the caller supplied a topic.
  create_alarm_topic = var.alarm_topic_arn == ""

  # What every alarm above publishes to.
  alarm_topic_arn = local.create_alarm_topic ? one(aws_sns_topic.alarms[*].arn) : var.alarm_topic_arn
}

# CloudWatch can't publish to an SNS topic encrypted with alias/aws/sns, so
# the topic created here uses a customer managed key:
# https://docs.aws.amazon.com/sns/latest/dg/sns-key-management.html#compatibility-with-aws-services
module "alarms_kms_key" {
  count = local.create_alarm_topic ? 1 : 0

  source  = "terraform-aws-modules/kms/aws"
  version = "4.2.2"

  description = "Customer managed key to encrypt the ${local.name} CloudWatch alarms SNS topic"

  key_administrators = [data.aws_iam_session_context.current.issuer_arn]

  key_statements = [
    {
      sid       = "AllowCloudWatchAlarms"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
      resources = ["*"]
      principals = [
        {
          type        = "Service"
          identifiers = ["cloudwatch.amazonaws.com"]
        }
      ]
    }
  ]

  aliases = ["eks/${local.name}/alarms"]
}

resource "aws_sns_topic" "alarms" {
  count = local.create_alarm_topic ? 1 : 0

  name              = "${local.name}-alarms"
  kms_master_key_id = one(module.alarms_kms_key[*].key_id)
}

resource "aws_sns_topic_subscription" "alarm_emails" {
  # alarm_email_addresses only applies to the topic this module owns; on a
  # caller-supplied topic, subscribe wherever that topic is defined.
  for_each = local.create_alarm_topic ? toset(var.alarm_email_addresses) : toset([])

  topic_arn = one(aws_sns_topic.alarms[*].arn)
  protocol  = "email"
  endpoint  = each.value
}
