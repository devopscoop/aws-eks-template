output "node_group_autoscaling_group_names" {
  description = "For the node CPU alarm in cluster/cloudwatch-alarms.tf"
  value       = module.node_group.node_group_autoscaling_group_names
}
