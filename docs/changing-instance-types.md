# Changing the node groups' instance types

Workloads that must not ride Karpenter capacity run on EKS managed node groups, one per zone. A node group's `instance_types` can't be changed in place. Changing it in `cluster/main.tf` makes OpenTofu create a new group and delete the old one in the same apply. Deleting a node group terminates its node about five minutes later whether or not its pods have moved off, and PodDisruptionBudgets don't stop it. Doing that to every node at once takes down anything that can't lose all of its pods at the same time.

So an instance-type change is a rotation to a new **generation** of node groups, in three steps:

1. **PR 1:** add the next generation of node groups with the new instance type, next to the current one. Nothing is deleted.
2. **By hand:** drain the old nodes one at a time, waiting until everything they ran is healthy on the new nodes.
3. **PR 2:** delete the old generation once its nodes are empty.

Node groups are named `ng-<zone>-<N>`, where N is the generation: a new cluster starts with `ng-a-1`, `ng-b-1` and `ng-c-1`, the first rotation adds `ng-a-2`, `ng-b-2` and `ng-c-2`, and so on. The number only goes up and is never reused. A node group's name comes from its map key, so renumbering a generation would replace its groups too. This procedure applies to anything else that replaces the groups too (a subnet or disk change, for example). Not to AMI and cluster version updates: those update the existing groups in place, and the per-AZ design handles them (see the comment above `eks_managed_node_groups` in `cluster/main.tf`).

## Before you start

- **The new type must fit the pods.** Check its allocatable memory and CPU against the requests of the largest pods that run on these nodes, plus the DaemonSets on every node (`kubectl describe node` on a current node shows both).
- **The new type must not throttle the disks.** An instance's EBS baseline caps all of its volumes together. It needs to cover the provisioned IOPS and throughput of every volume attached to the node (see the `instance_types` comment in `cluster/main.tf`).
- **The type must be offered in all three zones.**
- **Every node must be Ready, and nothing should already be disrupted.** A hung node wedges everything below, and a PDB that's already at its limit blocks the first drain.

  ```shell
  kubectl get nodes -L eks.amazonaws.com/nodegroup,topology.kubernetes.io/zone,node.kubernetes.io/instance-type
  kubectl get pdb -A
  kubectl get pods -A | grep -vE 'Running|Completed'     # nothing stuck
  ```

- **Pick a quiet time.** Workloads that fail over when their node is drained pause briefly while they do.

## 1. Add the next generation (PR 1)

The node groups are generated from `local.node_group_generations` in `cluster/main.tf`: one entry per generation, keyed by generation number, expanded to one group per zone over `local.availability_zones`.

```hcl
locals {
  # Node group generations by number; generation N's groups are ng-<zone>-<N>.
  # Changing instance_types replaces a group, so add a generation, move the
  # workloads, then delete the old one: docs/changing-instance-types.md.
  node_group_generations = {
    1 = { instance_types = ["t3a.large"] } # whatever the file has today
  }

  # One node group per generation per zone, each carrying its zone's index so
  # the group can pin itself to that zone's private subnet.
  node_groups = merge([
    for generation, group in local.node_group_generations : {
      for i, az in local.availability_zones : "ng-${trimprefix(az, local.region)}-${generation}" => merge(group, { az_index = i })
    }
  ]...)
}

  eks_managed_node_groups = {
    for key, group in local.node_groups : key => {
      subnet_ids = [module.vpc.private_subnets[group.az_index]]
      # ... unchanged ...
      instance_types = group.instance_types
      # ... unchanged ...
    }
  }
```

The rotation PR then adds an entry with the next number:

```hcl
  node_group_generations = {
    1 = { instance_types = ["t3a.large"] }
    2 = { instance_types = ["<new type>"] }
  }
```

**Read the plan before merging.** It must contain only `+`: the three new node groups, their launch templates and IAM roles, and three CPU alarms (`cluster/cloudwatch-alarms.tf` makes one per group). Any `-` or `-/+` on an `aws_eks_node_group` means a live group would be replaced. Stop and fix the change.

After the apply, wait for the new nodes to be Ready. There is one per zone, with the same `CriticalAddonsOnly` taint as the old ones. Nothing moves yet: Kubernetes doesn't reschedule running pods onto new nodes.

```shell
kubectl get nodes -L eks.amazonaws.com/nodegroup,topology.kubernetes.io/zone,node.kubernetes.io/instance-type
```

## 2. Drain the old nodes, one at a time

`kubectl drain` cordons a node and evicts its pods through the Eviction API, so every PDB gets a say. A pod with a zonal EBS volume can only move to the new node in its own zone; everything else can go wherever its tolerations and affinity allow.

For the first old node:

```shell
kubectl drain <old node> --ignore-daemonsets --delete-emptydir-data
```

Then wait until the cluster is back to steady state before touching the next one:

```shell
kubectl get pods -A -o wide --field-selector spec.nodeName=<old node>   # only DaemonSet pods left
kubectl get pods -A | grep -vE 'Running|Completed'                       # nothing Pending or unready
kubectl get pdb -A                                                       # allowed disruptions back to normal
```

- `FailedAttachVolume … waiting on detach` events for a few minutes are normal while EBS moves a volume to the new node.
- If the drain sits on "Cannot evict pod as it would violate the pod's disruption budget", the PDB is doing its job. Some operators keep a PDB at zero allowed disruptions and move the pod themselves once its node is cordoned; the drain keeps retrying until they have. Don't bypass it with `--disable-eviction`.
- Repeat for the other two old nodes. Draining two at once is exactly the failure this procedure exists to avoid.

## 3. Delete the old generation (PR 2)

Make sure nothing but DaemonSet pods is left on the old nodes:

```shell
kubectl get pods -A -o wide | grep -E '<old node 1>|<old node 2>|<old node 3>'
```

Then open PR 2, which removes the old generation from `node_group_generations`. Its plan must contain only `-`, for the old node groups and their launch templates, IAM roles and alarms. The workflow's node group guard (`.github/scripts/guard-node-group-removal.sh`, once it is in) refuses to apply a plan that removes a group whose nodes still have PVC-backed volumes attached, so if the apply fails here, a pod with a volume is still on the old nodes. Once it applies, update the `instance_types` comment in `cluster/main.tf` with the new type and why it was chosen.

## If something goes wrong

**A moved pod stays Pending.** Read `kubectl describe pod <pod> -n <namespace>`. Usually the new node in its zone is not Ready, or is short of memory. Uncordon the old node (`kubectl uncordon <old node>`) so the pod can go back while you investigate; a cluster split across two generations is fine to leave in place.

**To abort the whole move,** uncordon the old nodes, drain the new ones the same way if anything has moved, and remove the new generation in a later PR.
