# Lab Exercise: Grove — Exploring Topology & Gang Scheduling with AI

**Duration:** ~12 minutes  
**Namespace:** `dynamo-lab`  
**Tools:** Claude Code (CLI) or Cursor

---

## Step 0 — Connect to your lab instance

Open a terminal and run the following command to connect Cursor to your Brev instance:

```bash
brev open <your-instance-name> cursor
```

For example:

```bash
brev open dynamo-sa-workshop-jbuenosantan-ba0543 cursor
```

> **Note:** Replace `<your-instance-name>` with the instance name assigned to you. Ask your instructor if you're unsure.

This opens a remote Cursor window connected to your lab instance, where kubectl is already configured to talk to the cluster.

---

## How this lab works

Instead of copying and pasting kubectl commands, you'll explore Grove by asking questions in natural language. Use Claude Code in your terminal or Cursor's AI chat — the AI has full access to your cluster via kubectl.

> **Tip:** You don't need to type the prompts below verbatim. Rephrase them in your own words — the AI will figure out what you need.

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

Ask your AI assistant to list the Grove resources that the operator created from your DynamoGraphDeployment.

### Prompt

```text
List all Grove resources (PodCliqueSets, PodCliques, and PodGangs) in the
dynamo-lab namespace. Explain what each one is and how they relate to each other.
```

### What you should learn

- There is one **PodCliqueSet** named `dynamo-lab` — created from your DGD
- There are four **PodClique** objects — one per component (frontend, planner, prefill worker, decode worker)
- There is one **PodGang** named `dynamo-lab-0` — the gang scheduling unit for replica set 0

**Follow-up prompt to go deeper:**

```text
Show me the ownership chain from one of the worker pods all the way up to the
DynamoGraphDeployment. What owns what?
```

The full ownership chain:

```text
DynamoGraphDeployment
  └── PodCliqueSet
        └── PodClique (one per component role)
              └── PodGang (scheduling unit)
              └── Pod(s) (the running containers)
```

---

## Exercise 2 — Read the topology placement decision

Grove supports topology-aware placement through `topologyConstraint`. This controls how pods are packed relative to the physical cluster topology (e.g., within the same NVSwitch domain, same rack, or same node).

### How topology constraints work

| Setting | Where to set it | Effect |
| --- | --- | --- |
| `topologyConstraint.packDomain` | PodCliqueSet, ScalingGroup, or PodClique | References a `ClusterTopology` by name and forces pods to be placed within the same topology domain |
| **Default (no constraint)** | — | K8s schedules pods wherever resources fit — this is the problem topology constraints solve |

In production GPU clusters, you'd set `packDomain` to ensure prefill and decode workers land on nodes connected by the same NVSwitch fabric, minimizing KV cache transfer latency.

### Prompt

```text
Look at the PodClique specs for the decode and prefill workers in the dynamo-lab
namespace. Do they have any topology constraints set? What labels identify each
component's role and scheduling queue?
```

### What you should learn

- In this lab deployment, **no topology constraint is set** — the default behavior where K8s schedules wherever it fits
- Each PodClique carries labels that encode its role:
  - `nvidia.com/dynamo-component-type` → `worker`
  - `nvidia.com/dynamo-sub-component-type` → `prefill` or `decode`
  - `nvidia.com/selector` → e.g., `dynamo-lab-decodeworker`
  - `kai.scheduler/queue` → `dynamo` (the KAI Scheduler queue)

**Follow-up prompt to explore topology:**

```text
If I wanted to add a topology constraint to this deployment so that prefill and
decode workers are packed within the same NVSwitch domain, where in the YAML would
I configure topologyConstraint.packDomain? Show me an example.
```

The AI should explain that you'd add it to the PodCliqueSet, ScalingGroup, or individual PodClique spec, referencing a `ClusterTopology` resource by name:

```yaml
# Example — at PodCliqueSet level
spec:
  template:
    topologyConstraint:
      packDomain:
        topologyName: "my-cluster-topology"
        domainType: "NVSwitch"
```

---

## Exercise 3 — Read the startup ordering

Gang scheduling isn't just about placement — it also controls startup sequencing. Ask the AI how this deployment handles component startup order.

### Prompt

```text
What startup ordering strategy is the PodCliqueSet in dynamo-lab using? List all
the cliques with their role names, replica counts, and minAvailable thresholds.
```

### What you should learn

- The startup type is `CliqueStartupTypeAnyOrder` — all four components can start in any order
- Each clique has `minAvailable: 1` and `replicas: 1`

**Follow-up prompt:**

```text
When would you use CliqueStartupTypeOrdered instead of AnyOrder? What are the
tradeoffs?
```

The AI should explain:

- **AnyOrder** is fine for this lab — our mocker containers start instantly
- **Ordered** is used in production GPU clusters where startup is expensive. It prevents wasted GPU memory reservations by ensuring dependencies (like etcd or the router) are healthy before GPU-heavy workers start
- The tradeoff: ordered startup is slower but avoids expensive failures; any-order is faster but risks cascading restarts if a dependency isn't ready

---

## Key Takeaways

1. **Grove is not user-facing** — users deploy a `DynamoGraphDeployment`, Grove resources are created automatically by the operator
2. **PodCliques encode topology** — labels on PodCliques tell the scheduler what role each pod plays
3. **PodGangs enforce atomicity** — the scheduler either places the entire gang or none of it
4. **Topology constraints control placement** — `topologyConstraint.packDomain` ensures pods land in the same physical domain (NVSwitch, rack, etc.). Without it, K8s schedules wherever it fits
5. **Startup ordering is a gang-level concern** — `AnyOrder` vs. `Ordered` controls whether components can boot concurrently or must wait for dependencies
