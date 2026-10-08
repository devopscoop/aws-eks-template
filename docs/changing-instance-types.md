# Changing the database nodes' instance types

The CNPG databases run on dedicated EKS managed node groups, one per zone. A node group's `instance_types` can't be changed in place. Changing it in `cluster/main.tf` makes OpenTofu create a new group and delete the old one in the same apply. Deleting a node group terminates its node about five minutes later whether or not the database has moved off, and PodDisruptionBudgets don't stop it. Doing that to every database node at once has taken a production database down.

So an instance-type change is a rotation to a new **generation** of node groups, in three steps:

1. **PR 1:** add the next generation of node groups with the new instance type, next to the current one. Nothing is deleted.
2. **By hand:** move each database instance from its old node to the new node in the same zone, one at a time, waiting until each is healthy.
3. **PR 2:** delete the old generation once nothing on it matters.

Generations are named `db-g<N>-<zone>`: `db-g2-a`, `db-g2-b`, `db-g2-c`, then `db-g3-…`. The number only goes up and is never reused. The current groups, `blue-a/b/c`, are generation 1 and keep their name: a node group's name comes from its map key, so renaming them would replace them. This procedure applies to anything else that replaces the groups too (a subnet or disk change, for example). Not to AMI and cluster version updates: those update the existing groups in place, and the per-AZ design handles them (see the comment above `eks_managed_node_groups` in `cluster/main.tf`).

This runbook uses **goalert** / **goalert-db** throughout; for another database substitute its namespace and Cluster name (`<app>`, `<app>-db`). `kubectl get clusters.postgresql.cnpg.io -A` lists them all. Move one cluster at a time.

## Before you start

- **The new type must fit the pods.** Check its allocatable memory and CPU against each database pod's requests: the postgres container, plus the barman sidecar, plus the agents and controllers that run on every node (a few GiB; check a current node with `kubectl describe node`).
- **The new type must not throttle the disks.** An instance's EBS baseline caps all of its volumes together. It needs to cover the data volume's provisioned IOPS and throughput plus the WAL volume (see the `instance_types` comment in `cluster/main.tf`).
- **The type must be offered in all three zones.**
- **The cluster must be healthy, with every node Ready.** A hung node wedges everything below.

  ```shell
  kubectl -n goalert get cluster goalert-db              # "Cluster in healthy state", 3 ready
  kubectl cnpg status goalert-db -n goalert              # primary, two streaming replicas
  kubectl get nodes -L eks.amazonaws.com/nodegroup,topology.kubernetes.io/zone,node.kubernetes.io/instance-type
  ```

- **Pick a quiet time.** The primary move in step 2.2 pauses writes for roughly a minute.

## 1. Add the next generation (PR 1)

The node groups are generated from `local.db_node_group_generations` in `cluster/main.tf`: one entry per generation, keyed by the name prefix of its groups, expanded to one group per zone. If `main.tf` doesn't have this map yet, add it in its own PR first, with only `blue` in it. Its plan must show **no changes**; the keys stay `blue-a`, `blue-b` and `blue-c`.

```hcl
locals {
  # The database node group generations, keyed by the name prefix of their
  # groups. "blue" is generation 1; renaming it would replace it. To change
  # instance types, add the next generation, move the databases, then remove
  # the old one: docs/changing-instance-types.md.
  db_node_group_generations = {
    blue = { instance_types = ["t3a.large"] } # whatever the file has today
  }

  # One node group per generation per zone, each carrying its zone's index so
  # the group can pin itself to that zone's private subnet.
  db_node_groups = merge([
    for generation, group in local.db_node_group_generations : {
      for i, az in local.blue_azs : "${generation}-${trimprefix(az, local.region)}" => merge(group, { az_index = i })
    }
  ]...)
}

  eks_managed_node_groups = {
    for key, group in local.db_node_groups : key => {
      subnet_ids = [module.vpc.private_subnets[group.az_index]]
      # ... unchanged ...
      instance_types = group.instance_types
      # ... unchanged ...
    }
  }
```

The rotation PR then adds an entry with the next number:

```hcl
  db_node_group_generations = {
    blue    = { instance_types = ["t3a.large"] }
    "db-g2" = { instance_types = ["<new type>"] }
  }
```

**Read the plan before merging.** It must contain only `+`: the three new node groups, their launch templates and IAM roles, and three CPU alarms (`cluster/cloudwatch-alarms.tf` makes one per group). Any `-` or `-/+` on an `aws_eks_node_group` means a live group would be replaced. Stop and fix the change.

After the apply, wait for the new nodes to be Ready. There is one per zone, with the same `CriticalAddonsOnly` taint as the old ones. The databases' affinity only requires the `eks.amazonaws.com/nodegroup` label to exist, so each pod could now run on either generation's node in its zone. Nothing moves yet: Kubernetes doesn't reschedule running pods onto new nodes.

```shell
kubectl get nodes -L eks.amazonaws.com/nodegroup,topology.kubernetes.io/zone,node.kubernetes.io/instance-type
```

## 2. Move the database to the new generation

Each instance's EBS volumes are zonal, so each instance can only go to the new node in its own zone. You choose which node by cordoning the old one first.

Find each instance's role, node and zone:

```shell
kubectl -n goalert get pods -l cnpg.io/cluster=goalert-db -L cnpg.io/instanceRole -o wide
kubectl get nodes -L eks.amazonaws.com/nodegroup,topology.kubernetes.io/zone
```

### 2.1 The replicas, one at a time

For the first replica:

```shell
kubectl cordon <old node in the replica's zone>
kubectl -n goalert delete pod <replica>
kubectl -n goalert get pods -l cnpg.io/cluster=goalert-db -o wide -w
```

The operator recreates the pod ("Creating new Pod to reattach a PVC") and it schedules onto the new node in that zone.

- `FailedAttachVolume … waiting on detach` events for a few minutes are normal while EBS moves the volumes.
- The pod is done when it's 2/2 Ready on the new node. With `probes.startup.type: streaming`, Ready means it is streaming from the primary, so you don't need a separate lag check. `kubectl cnpg status goalert-db -n goalert` shows it as a streaming replica.

Cordoning a replica's node doesn't make CNPG do anything; it only reacts when the *primary's* node is cordoned. Deleting the pod bypasses the replica PDB, which is why you do one replica at a time and only when the cluster is healthy.

Repeat for the second replica. Don't start it until the first is Ready.

### 2.2 The primary

With both replicas Ready on new nodes, cordon the primary's old node:

```shell
kubectl cordon <old node in the primary's zone>
```

The operator logs "Current primary is running on unschedulable node, triggering a switchover" and promotes one of the replicas on the new nodes. Writes pause until `goalert-db-rw` points at the new primary, about 30–60 seconds. Watch for:

```shell
kubectl -n goalert get cluster goalert-db -o jsonpath='{.status.currentPrimary} {.status.phase}{"\n"}'
```

The old primary restarts as a replica **in its pod on the old node**. Once the cluster reports healthy again, move that pod too:

```shell
kubectl -n goalert delete pod <old primary>
```

To choose the new primary, or the time, yourself, run `kubectl cnpg promote goalert-db <replica on a new node> -n goalert` before cordoning.

### 2.3 Check

All three instances should be on the new generation's nodes, 3/3 ready, one primary and two streaming replicas:

```shell
kubectl -n goalert get pods -l cnpg.io/cluster=goalert-db -o wide
kubectl cnpg status goalert-db -n goalert
```

## 3. Drain and delete the old generation (PR 2)

Make sure no CNPG pod is left on an old node. Every node in the first listing must belong to a new-generation group in the second:

```shell
kubectl get pods -A -l cnpg.io/cluster -o custom-columns=NAMESPACE:.metadata.namespace,POD:.metadata.name,NODE:.spec.nodeName
kubectl get nodes -L eks.amazonaws.com/nodegroup
```

Drain the old nodes, so the controllers that also tolerate the taint (karpenter, coredns, the CSI and snapshot controllers) move under their PDBs instead of being killed by the delete:

```shell
kubectl drain <old node> --ignore-daemonsets --delete-emptydir-data
```

Then open PR 2, which removes the old generation from `db_node_group_generations`. Its plan must contain only `-`, for the old node groups and their launch templates, IAM roles and alarms. The workflow's node group guard (`.github/scripts/guard-node-group-removal.sh`, once it is in) refuses to apply a plan that removes a group whose nodes still have PVC-backed volumes attached, so if the apply fails here, a database is still on the old nodes. Once it applies, update the `instance_types` comment in `cluster/main.tf` with the new type and why it was chosen.

## If something goes wrong

**A moved replica stays Pending.** Read `kubectl -n goalert describe pod <pod>`. Usually the new node is not Ready or is short of memory. To put the instance back where it was, uncordon its old node and delete the Pending pod. A database split across two generations is fine to leave in place while you investigate.

**To abort the whole move,** uncordon the old nodes and move every instance back onto them the same way. Remove the new generation in a later PR.

**The primary pod is gone and the cluster won't come back.** This is a CloudNativePG deadlock (seen with 1.28) when the primary's pod disappears while the replicas are not yet Ready. You're in it when:

- `status.currentPrimary` names an instance with no pod, and its PVCs are listed in `status.danglingPVC`.
- The replicas are Running but unready, logging "could not connect to the primary server" and "waiting for WAL to become available".
- The operator logs "Waiting for the Kubelet to refresh the readiness probe" every second.

The `streaming` startup probe the CNPG database template sets is deliberate, so don't change it. Delete the orphaned replica pods instead, but **not** their PVCs:

```shell
kubectl -n goalert delete pod <replica-1> <replica-2>
```

With no instance pods left, the operator recreates the primary's pod first, on its own volumes, then the replicas. That gives no failover and no `pg_rewind`. Save `kubectl cnpg promote` for when the primary's volumes are actually gone.
