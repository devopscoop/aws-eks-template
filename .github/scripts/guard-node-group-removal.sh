#!/usr/bin/env bash
# Refuse a plan that deletes or replaces an EKS managed node group whose nodes
# still have PersistentVolumeClaim-backed EBS volumes attached.
#
# Deleting a managed node group terminates its nodes a few minutes later
# regardless of PodDisruptionBudgets, and an instance_types change is a
# replacement (delete + create) of the group. Applying such a plan with every
# CloudNativePG instance still on the groups being replaced kills every
# database node within about a minute of each other, which has taken a
# production database down. The safe procedure — add the next generation of
# groups, move the databases by hand, then delete the old generation — is
# docs/changing-instance-types.md. This guard makes the apply refuse to skip
# it.
#
# Why volumes rather than pods: the cluster's API endpoint is private and CI
# runs outside the VPC (AGENTS.md), so the workflow cannot list pods. But every
# PVC a pod holds is an EBS volume attached to that pod's node, and the EBS CSI
# driver tags each one with kubernetes.io/created-for/pvc/{namespace,name}.
# On the database node groups the only PVCs are the databases', so "is a PVC
# still attached to this group's nodes" is the question we want answered, and
# it is answerable with EC2 describe calls alone. The tags name the PVC for
# the report.
#
# Usage: guard-node-group-removal.sh <plan file>
#   Run from cluster/ after `tofu plan -out=<plan file>`, with AWS credentials
#   in the environment (the workflow's OIDC role; locally, AWS_PROFILE).
#   Writes a report to $GUARD_REPORT (default node-group-guard.txt) and exits:
#     0  the plan removes no node group, or none of the removed groups still
#        has a PVC-backed volume attached
#     1  a group being removed still has a PVC-backed volume attached
#   Any other failure (AWS API error, missing tool) exits non-zero as well:
#   the guard fails closed, and the workflow refuses to apply.
set -euo pipefail

plan=${1:?usage: $0 <plan file>}
report=${GUARD_REPORT:-node-group-guard.txt}
: >"$report"

say() { printf '%s\n' "$*" | tee -a "$report"; }

trap 'rc=$?; if ((rc > 1)); then say "Node group guard could not evaluate the plan (exit $rc); refusing to apply."; fi' EXIT

# Node groups whose change actions include "delete": a plain delete is
# ["delete"]; a replacement is ["delete", "create"] or ["create", "delete"].
mapfile -t removed < <(
  tofu show -json "$plan" | jq -r '
    .resource_changes[]?
    | select(.type == "aws_eks_node_group" and (.change.actions | index("delete")))
    | [.change.before.cluster_name, .change.before.node_group_name, (.change.actions | join("+"))]
    | @tsv'
)

if ((${#removed[@]} == 0)); then
  say "Node group guard: this plan deletes or replaces no EKS managed node group."
  exit 0
fi

blocked=0
for row in "${removed[@]}"; do
  IFS=$'\t' read -r cluster name actions <<<"$row"

  # A managed node group owns exactly one Auto Scaling group; its instances
  # are the nodes. Text output prints "None" for a null and nothing for an
  # empty list, so strip both.
  mapfile -t asgs < <(
    aws eks describe-nodegroup --cluster-name "$cluster" --nodegroup-name "$name" \
      --query 'nodegroup.resources.autoScalingGroups[].name' --output text \
      | tr '\t' '\n' | sed '/^$/d; /^None$/d'
  )
  instances=()
  if ((${#asgs[@]} > 0)); then
    mapfile -t instances < <(
      aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${asgs[@]}" \
        --query 'AutoScalingGroups[].Instances[].InstanceId' --output text \
        | tr '\t' '\n' | sed '/^$/d; /^None$/d'
    )
  fi
  if ((${#instances[@]} == 0)); then
    say "Node group $name ($actions): no instances, so nothing is attached. OK."
    continue
  fi

  # Volumes the EBS CSI driver created for a PVC, attached to any of the
  # group's instances. One row per volume: id, namespace, PVC name, instance.
  volumes=$(
    aws ec2 describe-volumes \
      --filters "Name=attachment.instance-id,Values=$(IFS=,; echo "${instances[*]}")" \
      "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
      --query 'Volumes[].[VolumeId, Tags[?Key==`kubernetes.io/created-for/pvc/namespace`]|[0].Value, Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value, Attachments[0].InstanceId]' \
      --output text
  )
  if [ -z "$volumes" ]; then
    say "Node group $name ($actions): ${#instances[@]} instance(s), no PVC-backed volume attached. OK."
    continue
  fi

  blocked=1
  say "Node group $name ($actions) still has PVC-backed volumes attached; a database is still on it:"
  while IFS=$'\t' read -r volume namespace pvc instance; do
    say "  $volume  PVC $namespace/$pvc  on $instance"
  done <<<"$volumes"
done

if ((blocked)); then
  say ""
  say "Refusing: deleting a node group terminates its nodes a few minutes later regardless of PodDisruptionBudgets."
  say "Move the databases off the groups above first (docs/changing-instance-types.md), then re-run."
  echo "::error title=Node group guard::This plan removes a node group that still has a database on it. See node-group-guard.txt."
  exit 1
fi

say "Node group guard: OK."
