################################################################################
# EC2 CPU CloudWatch alarms
#
# Vanta's "Server CPU monitored (AWS)" test requires every EC2 instance to be
# covered by a CloudWatch alarm on the CPUUtilization metric. The managed node
# group nodes are launched and replaced by an Auto Scaling Group, so
# per-instance alarms can't be declared statically in Terraform. Instead each
# node group gets one alarm on the AWS/EC2 CPUUtilization metric scoped to its
# ASG. The Maximum statistic is the highest per-instance value in each period,
# so the alarm fires when ANY node in the group runs hot — per-node alerting
# semantics without per-instance resources. CPU monitoring supports SOC 2
# CC7.2 (System Monitoring) and ISO/IEC 27001:2022 Annex A 8.16 (Monitoring
# activities).
#
# Vanta resolves an instance's ASG membership, so this ASG-scoped alarm is
# sufficient on its own for managed node group instances — it does not also
# need one dimensioned on InstanceId. Confirmed against a live cluster on
# 2026-08-31: the test passed for every managed node group instance while
# this was the only EC2 CPUUtilization alarm in the account.
#
# What it cannot cover is an instance belonging to no ASG. On clusters running
# Karpenter (fluxcd-template's apps/karpenter) nodes are launched through EC2
# Fleet and carry no aws:autoscaling:groupName tag, so nothing here matches
# them and Vanta flags each one. Alarming on them would mean per-instance
# alarms created and deleted as nodes churn — Karpenter consolidates and
# expires nodes continuously — which needs a reconciler or an EventBridge
# Lambda holding CloudWatch write credentials. fluxcd-template takes the
# cheaper route instead and tags those nodes VantaNoAlert in
# apps/karpenter-custom-resources/ec2nodeclass.yaml, on the grounds that node
# CPU is already alerted on in-cluster by node-exporter's NodeCPUHighUsage
# rule. Per the VantaNoAlert note in AGENTS.md, that takes those instances out
# of scope for every Vanta test, not just this one.
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

  alarm_actions = [local.alarm_topic_arn]
  ok_actions    = [local.alarm_topic_arn]
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

  alarm_actions = [local.alarm_topic_arn]
  ok_actions    = [local.alarm_topic_arn]
}

################################################################################
# NLB target-group health CloudWatch alarms
#
# The AWS Load Balancer Controller creates an NLB (plus one target group per
# listener port) for every LoadBalancer Service in the cluster — the Envoy
# Gateway gateways from the companion fluxcd-template repo, which are the
# cluster's only traffic entry points. When a target group has no healthy
# targets, the cluster is down from the internet's perspective no matter what
# the pods think, so that's the signal to alarm on. Load balancer monitoring
# supports SOC 2 CC7.2 (System Monitoring) and ISO/IEC 27001:2022 Annex A 8.16
# (Monitoring activities).
#
# The controller mints the LB and target-group names (k8s-envoygat-…/<hash>),
# and re-mints them whenever a Service is recreated or its traffic config
# materially changes, so per-target-group alarms can't be declared statically
# the way the node CPU alarms can. Hand-pinning the generated ARN suffixes has
# been tried in a fork and rotted within days of an LB replacement. Instead,
# discover the dimensions through the controller's own tags: every LB and
# target group it manages carries elbv2.k8s.aws/cluster = <cluster name> and
# service.k8s.aws/stack = <namespace>/<service>, and each target group names
# its listener in service.k8s.aws/resource = <namespace>/<service>:<port>.
# https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/configurations/#aws-resource-tags
#
# The discovery trade-off: data sources read at plan time, so alarm coverage
# is only as fresh as the last pipeline run. Two consequences to know about:
#
#  - On a cluster where Flux hasn't created the gateway Services yet (first
#    bootstrap), the lookups match nothing and no alarms exist. They appear on
#    the first apply after the NLBs do — merge any PR, or re-run the apply
#    workflow, once the gateways are up.
#  - If a Service is recreated, the alarms keep the dead dimensions until the
#    next apply. treat_missing_data = "breaching" below makes that state page
#    loudly instead of sitting quietly in INSUFFICIENT_DATA while monitoring
#    nothing — the fix is simply to re-run the pipeline, which re-reads the
#    tags and updates the dimensions in place.
################################################################################

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

  # <namespace>-<service>-<port> (the service.k8s.aws/resource tag, sanitized
  # for use in alarm names) => that target group's CloudWatch dimension pair.
  # Target groups whose stack no longer has an LB are skipped: the controller
  # can leave orphaned target groups behind, and an alarm on one could never
  # receive data again.
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

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
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

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

################################################################################
# Alarm notification delivery
#
# An alarm with no action satisfies the Vanta test but alerts no one, so alarm
# state changes publish to an SNS topic.
#
# Which topic depends on alarm_topic_arn. Set it and the alarms publish to a
# topic that already exists in the account — the right answer whenever there
# is one with a chat or paging integration hanging off it, because a topic
# created here starts with no subscribers and stays that way until someone
# remembers to populate alarm_email_addresses. An unsubscribed topic is the
# failure mode this variable exists to avoid: the alarms look configured, the
# Vanta test passes, and nothing reaches a human.
#
# Left empty, this module creates its own topic and subscribes
# alarm_email_addresses to it (each address must click the confirmation link
# SNS emails it), which keeps the template self-contained for a standalone
# cluster.
################################################################################

locals {
  # Nothing to create when the caller supplied a topic.
  create_alarm_topic = var.alarm_topic_arn == ""

  # What every alarm above publishes to.
  alarm_topic_arn = local.create_alarm_topic ? one(aws_sns_topic.alarms[*].arn) : var.alarm_topic_arn
}

# CloudWatch alarms cannot publish to an SNS topic encrypted with the
# AWS-managed alias/aws/sns key, because that key's policy can't be edited to
# let the CloudWatch service use it. A customer managed key with the
# cloudwatch.amazonaws.com grants below is the AWS-documented fix:
# https://docs.aws.amazon.com/sns/latest/dg/sns-key-management.html#compatibility-with-aws-services
#
# Only relevant to the topic this module creates. A caller-supplied topic
# brings its own encryption decision, and must already let CloudWatch publish
# to it — an unencrypted topic does by default.
module "alarms_kms_key" {
  count = local.create_alarm_topic ? 1 : 0

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
