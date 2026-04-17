# Lab Exercise: Grove — Reading Topology & Gang Scheduling State

**Duration:** ~12 minutes  
**Namespace:** `dynamo-lab`

---

## Background

When you applied the `DynamoGraphDeployment` manifest, the Dynamo operator translated your service definitions into Grove resources. Grove is NVIDIA's Kubernetes operator for topology-aware gang scheduling — it ensures that all components of a disaggregated inference pipeline are scheduled together as a unit (not piecemeal).

The key resources Grove creates:

| Resource | What it represents |
|---|---|
| **PodCliqueSet** (pcs) | The top-level group — holds all cliques for one deployment |
| **PodClique** (pclq) | One component role (e.g., decode worker) with its pod template |
| **PodGang** (pg) | The scheduling unit — all pods that must be co-scheduled together |

---

## Exercise 1 — Discover the Grove resources

List all Grove resources in the namespace:

```bash
kubectl get podcliquesets,podcliques,podgangs -n dynamo-lab
```

**What you see:**
- One `PodCliqueSet` named `dynamo-lab` — the operator created this from your DGD
- Four `PodClique` objects — one per component (frontend, planner, prefill worker, decode worker)
- One `PodGang` named `dynamo-lab-0` — the gang scheduling unit for replica set 0

**Q: Why does the PodCliqueSet name match the DGD name?**  
The operator creates exactly one PodCliqueSet per DynamoGraphDeployment and names it identically.

---

## Exercise 2 — Read the topology placement decision

Each PodClique has labels that encode the topology. Inspect the decode worker's clique:

```bash
kubectl get podclique dynamo-lab-0-decodeworker -n dynamo-lab -o json \
  | jq '.metadata.labels | {type: ."nvidia.com/dynamo-component-type", subtype: ."nvidia.com/dynamo-sub-component-type", selector: ."nvidia.com/selector", queue: ."kai.scheduler/queue"}'
```

Expected output:
```json
{
  "type": "worker",
  "subtype": "decode",
  "selector": "dynamo-lab-decodeworker",
  "queue": "dynamo"
}
```

These labels are how:
- The **KAI Scheduler** knows which scheduling queue to use (`kai.scheduler/queue: dynamo`)
- The Dynamo operator knows whether this is a prefill or decode worker (`subtype`)
- The planner and router know how to route KV cache tokens

**Try it for the prefill worker:**

```bash
kubectl get podclique dynamo-lab-0-prefillworker -n dynamo-lab -o json \
  | jq '.metadata.labels | ."nvidia.com/dynamo-sub-component-type"'
```

---

## Exercise 3 — Read the startup ordering

Look at how the PodCliqueSet specifies startup sequencing:

```bash
kubectl get podcliqueset dynamo-lab -n dynamo-lab -o json \
  | jq '.spec.template.cliqueStartupType'
```

You will see: `"CliqueStartupTypeAnyOrder"`

This means all four components (frontend, planner, prefill, decode) are allowed to start in any order. In a production GPU cluster with GPU-intensive startup, you might see `CliqueStartupTypeOrdered` to prevent wasted GPU memory reservations.

**See the list of cliques and their ordering:**

```bash
kubectl get podcliqueset dynamo-lab -n dynamo-lab -o json \
  | jq '[.spec.template.cliques[] | {name: .name, role: .spec.roleName, minAvailable: .spec.minAvailable, replicas: .spec.replicas}]'
```

Expected output:
```json
[
  {"name": "prefillworker","role": "prefillworker", "minAvailable": 1, "replicas": 1},
  {"name": "decodeworker", "role": "decodeworker", "minAvailable": 1, "replicas": 1},
  {"name": "frontend",     "role": "frontend",     "minAvailable": 1, "replicas": 1},
  {"name": "planner",      "role": "planner",      "minAvailable": 1, "replicas": 1}
]
```

`minAvailable: 1` is the quorum threshold — if fewer than this many pods are running for a clique, the PodGang is considered degraded.

---

## Exercise 4 — Read the gang scheduling state

The `PodGang` is what the KAI Scheduler actually sees. It holds the live mapping from scheduling groups → pod references:

```bash
kubectl get podgang dynamo-lab-0 -n dynamo-lab -o json \
  | jq '[.spec.podgroups[] | {group: .name, minReplicas: .minReplicas, pods: [.podReferences[].name]}]'
```

You will see all four component groups with their actual pod names. This is the **atomic unit** — KAI will only bind these pods to nodes if resources exist for all of them together.

**Check the gang's owner:**

```bash
kubectl get podgang dynamo-lab-0 -n dynamo-lab -o json \
  | jq '.metadata.ownerReferences[] | {kind: .kind, name: .name}'
```

Output: `{"kind": "PodCliqueSet", "name": "dynamo-lab"}` — the PodGang is owned by the PodCliqueSet, which is owned by the DGD.

---

## Exercise 5 — Trace the ownership chain

In a real support scenario, if you find a stuck pod, you can trace upward through ownership to find the root cause. Try it:

```bash
# Start from a worker pod
PREFILL_POD=$(kubectl get pod -n dynamo-lab -l nvidia.com/selector=dynamo-lab-prefillworker -o jsonpath='{.items[0].metadata.name}')
echo "Pod: $PREFILL_POD"

# The pod's owner is the PodClique
kubectl get pod -n dynamo-lab $PREFILL_POD -o json \
  | jq '.metadata.ownerReferences[] | {kind: .kind, name: .name}'

# The PodClique's owner is the PodCliqueSet
kubectl get podclique -n dynamo-lab dynamo-lab-0-prefillworker -o json \
  | jq '.metadata.ownerReferences[] | {kind: .kind, name: .name}'

# The PodCliqueSet's owner is the DGD
kubectl get podcliqueset -n dynamo-lab dynamo-lab -o json \
  | jq '.metadata.ownerReferences[] | {kind: .kind, name: .name}'
```

Full ownership chain:
```
DynamoGraphDeployment
  └── PodCliqueSet
        └── PodClique (one per component role)
              └── PodGang (scheduling unit)
              └── Pod(s) (the running containers)
```

---

## Key Takeaways

1. **Grove is not user-facing** — users deploy a `DynamoGraphDeployment`, Grove resources are created automatically by the operator
2. **PodCliques encode topology** — labels on PodCliques tell the scheduler what role each pod plays
3. **PodGangs enforce atomicity** — the scheduler either places the entire gang or none of it
4. **`minAvailable`** is the quorum threshold — operators tune this for fault tolerance vs. scheduling flexibility
5. **The ownership chain** (`DGD → PodCliqueSet → PodClique → Pod`) is how you trace issues from pods back to the deployment intent
