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

The Dynamo Planner is an SLA-driven autoscaler for disaggregated LLM serving. It reads metrics from Prometheus, predicts future load, and scales prefill/decode workers to meet SLA targets.

In this lab the workers are mock inference engines (no GPUs needed). The mocker reports a constant TTFT of ~10ms. We'll tighten the SLA target below that threshold so the Planner is forced to scale — simulating what happens in production when real GPUs are under heavy load.

---

## Exercise 1 — See what you have

Ask the AI to show you the current state of the deployment — the Planner's configuration and the pods that are running.

### Prompt

```text
Show me the Planner configuration from the DynamoGraphDeployment in the
dynamo-lab namespace. What are the SLA targets? Then list all the pods
running in the namespace.
```

### What you should learn

- The Planner is configured with `"ttft":2000` (TTFT target) and `"itl":200` (ITL target)
- The adjustment interval is 30 seconds
- There are 4 pods running: frontend, planner, one prefill worker, one decode worker

---

## Exercise 2 — Generate load and scale the environment

Lower the TTFT SLA target so it's below the mocker's ~10ms baseline, then send traffic. The Planner will detect an SLA violation and scale out.

### Prompt

```text
Edit the DynamoGraphDeployment "dynamo-lab" in the dynamo-lab namespace and
change the TTFT target from 2000 to 5 in the Planner's --config args. Then
run the load generator at ~/dynamo-lab/load-gen.py at 5 requests per second
for 120 seconds.
```

Once the AI confirms the load generator is running, open a terminal in Cursor and run:

```bash
kubectl get pods -n dynamo-lab
```

### What you should learn

- With TTFT target at 5ms and observed TTFT at ~10ms, the Planner detects an SLA violation
- You'll see a new prefill worker pod being provisioned (status `ContainerCreating` → `Running`)
- This is the same math that runs in production — `demand / capacity = workers needed`

---

## Exercise 3 — Stop load and watch the pod go away

Stop the load and restore the original SLA target. The Planner will determine the extra workers are no longer needed.

### Prompt

```text
Stop the load generator. Change the TTFT target back to 2000 in the
DynamoGraphDeployment. Watch the pods — does the extra worker get
terminated?
```

### What you should learn

- After load stops and the SLA target is restored, the Planner computes that 1 worker is sufficient
- The extra prefill worker pod terminates
- The Planner does **not** scale down to 0 — `min_endpoint` (default: 1) keeps at least one prefill and one decode worker running to avoid cold-start delays

---

## Key Takeaways

1. **The Planner is a control loop** — it runs every 30 seconds, regardless of traffic
2. **SLA targets drive scaling** — when observed TTFT or ITL approaches the target, the Planner adds workers
3. **Scaling is bidirectional** — workers are added under load and removed when load drops
4. **Profiling data drives capacity math** — each worker's capacity comes from pre-run profiling of the GPU/model combination
5. **min_endpoint prevents scale-to-zero** — at least one worker per role is always running
