# Lab Exercise: Planner — Exploring SLA-Driven Autoscaling with AI

**Duration:** ~15 minutes  
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

The Dynamo Planner is an SLA-driven autoscaler for disaggregated LLM serving. It:

1. **Reads metrics** from Prometheus (TTFT, ITL, request rate, ISL, OSL) scraped from the frontend
2. **Predicts future load** using a time-series model (pmdarima ARIMA by default)
3. **Computes the optimal number** of prefill and decode workers to meet SLA targets
4. **Scales** the PodCliques via the DynamoGraphDeployment or Kubernetes replica counts

The SLA targets in this deployment:

- **TTFT target:** 2000 ms (time to first token)
- **ITL target:** 200 ms (inter-token latency)
- **Adjustment interval:** 30 seconds

---

## Exercise 1 — Read the Planner configuration

Ask your AI assistant to find and explain the Planner's configuration.

### Prompt

```text
Look at the Planner PodClique in the dynamo-lab namespace and extract its
configuration arguments. Explain what each config field means — especially the
SLA targets, the adjustment interval, and the backend type.
```

### What you should learn

The Planner is configured via a `--config` JSON payload. Key fields:

| Field | Value | Meaning |
| --- | --- | --- |
| `environment` | `kubernetes` | Planner runs in K8s mode, reads/writes DGD replicas |
| `backend` | `mocker` | Workers are inference simulators (not real GPUs) |
| `ttft` | 2000 | TTFT SLA target in milliseconds |
| `itl` | 200 | ITL SLA target in milliseconds |
| `throughput_adjustment_interval` | 30 | Seconds between scaling decisions |
| `max_gpu_budget` | -1 | Unlimited budget (no GPU cap) |
| `no_correction` | true | Disable correction factor (steady-state mode) |
| `prefill_engine_num_gpu` | 1 | Each prefill worker uses 1 GPU equivalent |
| `decode_engine_num_gpu` | 1 | Each decode worker uses 1 GPU equivalent |

---

## Exercise 2 — Watch the Planner logs in real time

Ask the AI to tail the Planner's logs so you can see its control loop in action — first with no traffic.

### Prompt

```text
Tail the Planner pod logs in the dynamo-lab namespace. Filter for lines that
show observed metrics, predictions, scaling calculations, or adjustment intervals.
```

### What you should learn

With no traffic, you'll see the Planner running its control loop every 30 seconds but skipping adjustments:

```text
Observed num_req: 0.00 isl: nan osl: nan
Observed ttft: nanms itl: nanms
Metrics contain None or NaN values (no active requests), skipping adjustment
```

The Planner is always running — it doesn't sleep when idle.

---

## Exercise 3 — Inject load and watch the Planner react

Now ask the AI to send traffic to the frontend and watch how the Planner observes and reacts to it.

### Prompt

```text
Run the load generator at ~/dynamo-lab/load-gen.py at 5 requests per second for
90 seconds. While it's running, tail the Planner logs and show me the observed
metrics and scaling calculations.
```

### What you should learn

After 30 seconds (one Planner interval), the logs will show:

```text
Observed num_req: 150.00 isl: 21.72 osl: 116.67
Observed ttft: 9.42ms itl: 0.94ms
Predicted load: num_req=150.00, isl=21.72, osl=116.67
Prefill calculation: 57.41(p_thpt) / 5121.58(p_engine_cap) = 1(num_p)
Decode calculation: 17435.94(d_thpt) / 18968.95(d_engine_cap) = 1(num_d)
```

**How to read the calculation:**

- `p_thpt` = predicted prefill throughput demand (tokens/s)
- `p_engine_cap` = single prefill worker's capacity (tokens/s from profiling data)
- `p_thpt / p_engine_cap` → rounded up → number of prefill workers needed

At 5 req/s the load fits within one worker's capacity, so `num_p = 1`.

**Follow-up prompt — understand why it doesn't scale:**

```text
The Planner computed num_p=1 and num_d=1 even under load. Why didn't it add
more workers? What would need to change for the Planner to scale out?
```

The AI should explain:

- The mocker simulates perfect H200 GPUs — TTFT stays ~10ms regardless of load
- The SLA target is 2000ms, so we're 200x under the limit
- In a real deployment, TTFT rises as the prefill queue fills. When `observed_ttft` approaches the target, the Planner adds prefill workers
- You could demonstrate scaling by lowering the TTFT target to 5ms in the DGD config (below what the mocker reports), which would trigger scale-out

---

## Exercise 4 — Stop load and watch the Planner go idle

Stop the load generator and ask the AI what happens.

### Prompt

```text
Stop the load generator and show me the Planner logs. Does it scale down to
zero workers when there's no traffic?
```

### What you should learn

The Planner logs will return to:

```text
New throughput adjustment interval started!
Observed num_req: 0.00 isl: nan osl: nan
Observed ttft: nanms itl: nanms
Metrics contain None or NaN values (no active requests), skipping adjustment
```

The Planner does **not** scale down to 0 when idle. `min_endpoint` (default: 1) ensures at least 1 prefill and 1 decode worker is always running — necessary to handle the first request after an idle period without a cold-start delay.

---

## Key Takeaways

1. **The Planner is a control loop** — it runs every `throughput_adjustment_interval` seconds, regardless of traffic
2. **It reads from Prometheus, not pods directly** — this means you can trace its inputs by querying Prometheus
3. **Scaling decisions are forward-looking** — the ARIMA predictor anticipates load changes, not just reacts
4. **Profiling data drives capacity math** — the `p_engine_cap` / `d_engine_cap` values come from pre-run profiling of the actual GPU/model combination
5. **SLA targets are TTFT + ITL** — these map to the user-facing experience: time until the first token appears, and smoothness of streaming

---

## Reference: Planner log messages

| Log message | Meaning |
| --- | --- |
| `New throughput adjustment interval started!` | Start of a 30-second scaling cycle |
| `Observed num_req: X` | Requests seen in the last interval from Prometheus |
| `Prefill calculation: X / Y = Z` | demand / capacity = workers needed |
| `Scaling to Z prefill workers` | Planner is writing a new replica count |
| `Metrics contain None or NaN` | No active traffic, scaling skipped |
| `Could not read GPU counts from DGD` | Falling back to CLI-configured GPU counts (normal for mocker) |
