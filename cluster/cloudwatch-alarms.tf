################################################################################
# EC2 CPU CloudWatch alarms
#
# Vanta's "Server CPU monitored (AWS)" test requires every EC2 instance to be
# covered by a CloudWatch alarm on the CPUUtilization metric. The only EC2
# instances here are the EKS managed node group nodes, which are launched and
# replaced by an Auto Scaling Group, so per-instance alarms can't be declared
# statically in Terraform. Instead each node group gets one alarm on the
# AWS/EC2 CPUUtilization metric scoped to its ASG. The Maximum statistic is
# the highest per-instance value in each period, so the alarm fires when ANY
# node in the group runs hot — per-node alerting semantics without
# per-instance resources. CPU monitoring supports SOC 2 CC7.2 (System
# Monitoring) and ISO/IEC 27001:2022 Annex A 8.16 (Monitoring activities).
#
# If Vanta keeps flagging individual instances after this is applied (i.e. its
# test only matches alarms by InstanceId, not by the instance's ASG), the
# fallback is automation that creates/deletes a per-instance alarm on EC2
# launch/terminate events — considerably more moving parts, so try this first.
################################################################################

locals {
  # Alert when any node in the group sustains this CPU percentage or higher
  # for node_cpu_alarm_minutes.
  node_cpu_alarm_threshold = 90
  node_cpu_alarm_minutes   = 15
}

resource "aws_cloudwatch_metric_alarm" "node_cpu" {
  # The map keys ("blue", ...) are the static node group names from main.tf,
  # so they're known at plan time even before the cluster exists; only the
  # ASG name inside dimensions is resolved at apply.
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

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

################################################################################
# SQS queue age CloudWatch alarms
#
# Vanta's "SQS queues monitored and alarmed" test requires every SQS queue to
# be covered by a CloudWatch alarm on the ApproximateAgeOfOldestMessage
# metric, which indicates message processing delays or queue blockage. Queue
# monitoring supports SOC 2 CC7.2 (System Monitoring) and ISO/IEC 27001:2022
# Annex A 8.16 (Monitoring activities).
#
# The only queue in this root module is Karpenter's interruption queue
# (karpenter.tf). A healthy Karpenter controller drains it within seconds, so
# a message sitting for minutes means interruption handling is down and spot
# reclaims / scheduled maintenance will hit nodes without graceful draining.
################################################################################

locals {
  # Alert when the oldest message has been in the queue at least this long for
  # queue_age_alarm_minutes. The Karpenter sub-module hardcodes the queue's
  # message_retention_seconds to 300, so this metric can never exceed 300 —
  # SQS silently drops older messages. The threshold must therefore stay well
  # below 300 or the alarm could never fire.
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

  # SQS only emits metrics for queues that have been active in the last ~6
  # hours; an idle interruption queue reports nothing at all. Without this the
  # alarm would sit in INSUFFICIENT_DATA through every quiet stretch — no
  # data means no stuck messages, so treat it as OK.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

################################################################################
# Alarm notification delivery
#
# An alarm with no action satisfies the Vanta test but alerts no one, so alarm
# state changes publish to an SNS topic. Subscribe your team via
# alarm_email_addresses in terraform.tfvars (each address must click the
# confirmation link SNS emails it), or hang chat/PagerDuty integrations off
# the topic later.
################################################################################

# CloudWatch alarms cannot publish to an SNS topic encrypted with the
# AWS-managed alias/aws/sns key, because that key's policy can't be edited to
# let the CloudWatch service use it. A customer managed key with the
# cloudwatch.amazonaws.com grants below is the AWS-documented fix:
# https://docs.aws.amazon.com/sns/latest/dg/sns-key-management.html#compatibility-with-aws-services
module "alarms_kms_key" {
  source  = "terraform-aws-modules/kms/aws"
  version = "4.2.1"

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
  name              = "${local.name}-alarms"
  kms_master_key_id = module.alarms_kms_key.key_id
}

resource "aws_sns_topic_subscription" "alarm_emails" {
  for_each = toset(var.alarm_email_addresses)

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.value
}
