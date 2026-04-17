# Lab Exercise: Planner — SLA-Driven Autoscaling with AI

**Duration:** ~10 minutes  
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

Instead of copying and pasting kubectl commands, you'll explore the Planner by asking questions in natural language. Use Claude Code in your terminal or Cursor's AI chat — the AI has full access to your cluster via kubectl.

> **Tip:** You don't need to type the prompts below verbatim. Rephrase them in your own words — the AI will figure out what you need.

---

## Background

The Dynamo Planner is an SLA-driven autoscaler for disaggregated LLM serving. It reads metrics from Prometheus, predicts future load, and scales prefill/decode workers to meet SLA targets. When the Planner decides to scale, it writes new replica counts to the `DynamoGraphDeployment`, which Grove turns into pods.

In this lab the workers are mock inference engines (no real GPUs). You'll scale the deployment directly through the DGD — the same mechanism the Planner uses in production — and watch pods come up and go away in real time.

---

## Exercise 1 — See what you have

Ask the AI to show you the current state of the deployment.

### Prompt

```text
Show me the Planner configuration from the DynamoGraphDeployment in the
dynamo-lab namespace. What are the SLA targets and how many replicas does
each service have? Then list all the pods running in the namespace.
```

### What you should learn

- The Planner is configured with `"ttft":2000` (TTFT target) and `"itl":200` (ITL target)
- Each service (Frontend, Planner, PrefillWorker, DecodeWorker) has 1 replica
- There are 4 pods running — one per service

---

## Exercise 2 — Scale out and watch a pod spin up

Ask the AI to increase the prefill worker replicas in the DGD. Then open a terminal in Cursor and watch the new pod appear.

### Prompt

```text
Scale the PrefillWorker replicas from 1 to 2 in the DynamoGraphDeployment
"dynamo-lab" in the dynamo-lab namespace.
```

Once the AI confirms the patch, open a terminal in Cursor and run:

```bash
kubectl get pods -n dynamo-lab
```

### What you should learn

- A new prefill worker pod appears (status `ContainerCreating` → `Running`)
- The DGD replica count is how the Planner controls scaling in production — you just did manually what the Planner does automatically when it detects SLA violations
- Grove creates the pod through the PodClique → PodGang ownership chain

---

## Exercise 3 — Scale down and watch the pod terminate

Scale back to 1 replica and watch the extra pod go away.

### Prompt

```text
Scale the PrefillWorker replicas back to 1 in the DynamoGraphDeployment.
```

Then in your terminal:

```bash
kubectl get pods -n dynamo-lab
```

### What you should learn

- The extra prefill worker pod terminates
- You're back to the original 4 pods
- In production, the Planner would do this automatically when load drops and fewer workers are needed
- The Planner does **not** scale to 0 — `min_endpoint` (default: 1) keeps at least one worker per role running to avoid cold-start delays

---

## Key Takeaways

1. **The Planner is a control loop** — it runs every 30 seconds, reads from Prometheus, and writes replica counts to the DGD
2. **SLA targets drive scaling** — when observed TTFT or ITL approaches the target, the Planner adds workers
3. **Scaling is bidirectional** — workers are added under load and removed when load drops
4. **The DGD is the control surface** — whether the Planner or an operator changes replica counts, the same Grove machinery creates and destroys pods
5. **min_endpoint prevents scale-to-zero** — at least one worker per role is always running
