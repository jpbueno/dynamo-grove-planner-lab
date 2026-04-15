# Lab Exercise: Planner — SLA-Driven Autoscaling

**Duration:** ~15 minutes  
**Namespace:** `dynamo-lab`

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

Look at how the Planner was configured in the DGD:

```bash
kubectl get podclique dynamo-lab-0-planner -n dynamo-lab -o json \
  | jq '.spec.podSpec.containers[0].args'
```

You'll see the `--config` argument with a JSON payload. Key fields:

| Field | Value | Meaning |
|---|---|---|
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

Open a second terminal and start tailing the planner logs. You'll watch it react to load changes you create in the main terminal.

```bash
# Terminal 2 - Keep this running
PLANNER_POD=$(kubectl get pod -n dynamo-lab -l nvidia.com/dynamo-component=Planner \
  -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n dynamo-lab $PLANNER_POD -f \
  | grep --line-buffered -E "Observed|Predicted|Prefill calculation|Decode calculation|Scaling|adjustment"
```

With no traffic, you'll see:
```
Observed num_req: 0.00 isl: nan osl: nan
Observed ttft: nanms itl: nanms
Metrics contain None or NaN values (no active requests), skipping adjustment
```

---

## Exercise 3 — Inject load and watch the Planner observe it

In your main terminal, send requests at a moderate rate for 90 seconds:

```bash
# Terminal 1
python3 ~/dynamo-lab/load-gen.py --rps 5 --duration 90
```

> The load generator auto-discovers the frontend service IP via `kubectl`. You can also pass it explicitly with `--url http://<frontend-ip>:8000`.

The load generator sends requests with varied prompt lengths (short, medium, long) to simulate real workloads.

After 30 seconds (one Planner interval), switch to the log terminal. You'll see the Planner report:
```
Observed num_req: 150.00 isl: 21.72 osl: 116.67
Observed ttft: 9.42ms itl: 0.94ms
Predicted load: num_req=150.00, isl=21.72, osl=116.67
Prefill calculation: 57.41(p_thpt) / 5121.58(p_engine_cap) = 1(num_p)
Decode calculation: 17435.94(d_thpt) / 18968.95(d_engine_cap) = 1(num_d)
```

**Read the calculation:**
- `p_thpt` = predicted prefill throughput demand (tokens/s)
- `p_engine_cap` = single prefill worker's capacity (tokens/s from profiling data)
- `p_thpt / p_engine_cap` → rounded up → number of prefill workers needed

At 5 req/s with our short prompts, the load is well within one worker's capacity, so `num_p = 1`.

---

## Exercise 4 — Query the Planner's Prometheus metrics

The Planner exposes its own metrics on port 9085. Port-forward to read them:

```bash
PLANNER_POD=$(kubectl get pod -n dynamo-lab -l nvidia.com/dynamo-component=Planner \
  -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n dynamo-lab pod/$PLANNER_POD 9085:9085 &

# Query the metrics
curl -s http://localhost:9085/metrics | grep "^planner:"
```

Key metrics to watch:

| Metric | What it tells you |
|---|---|
| `planner:num_p_workers` | Current prefill worker count |
| `planner:num_d_workers` | Current decode worker count |
| `planner:observed_ttft` | Measured TTFT over last interval (ms) |
| `planner:observed_itl` | Measured ITL over last interval (ms) |
| `planner:observed_request_rate` | Requests per second seen |
| `planner:predicted_num_p` | Target number of prefill workers |
| `planner:predicted_num_d` | Target number of decode workers |
| `planner:gpu_hours` | Simulated GPU-hour cost of current deployment |

While load is running at 5 req/s you should see:
```
planner:observed_request_rate 5.0
planner:observed_ttft 9.42     # well within 2000ms SLA
planner:predicted_num_p 1.0
planner:predicted_num_d 1.0
```

---

## Exercise 5 — See the Planner read from Prometheus directly

The Planner's source of truth is Prometheus, not direct pod metrics. You can see what it's reading:

**Note:** Run this while load is active (Exercise 3) to see non-NaN values.

```bash
PROM_IP=$(kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus \
  -o jsonpath='{.spec.clusterIP}')

# Average TTFT over last 30s (same query the Planner uses)
curl -s "http://$PROM_IP:80/api/v1/query" \
  --data-urlencode 'query=increase(dynamo_frontend_time_to_first_token_seconds_sum[30s])/increase(dynamo_frontend_time_to_first_token_seconds_count[30s])' \
  | jq '.data.result[0].value[1]'

# Request count in last 30s
curl -s "http://$PROM_IP:80/api/v1/query" \
  --data-urlencode 'query=increase(dynamo_frontend_requests_total[30s])' \
  | jq '.data.result[0].value[1]'
```

This gives you the raw Prometheus values the Planner uses to make its scaling decision.

---

## Exercise 6 — Understand why the Planner doesn't scale here

With our mocker setup, TTFT stays ~10ms regardless of load (the mocker simulates perfect H200 GPUs). Since TTFT is 10ms vs. our 2000ms target — we're 200x under the limit. The Planner correctly computes that 1 prefill + 1 decode worker is sufficient.

In a real deployment:
- TTFT rises under load as the prefill queue fills
- When `observed_ttft` approaches the target, the Planner adds prefill workers
- When `observed_itl` approaches its target, the Planner adds decode workers

You can simulate hitting the SLA by lowering the targets in the DGD:

```bash
# To demonstrate scaling, reduce the TTFT target to 5ms (below what the mocker reports)
# (this is for demonstration only — would cause rapid scale-out)
kubectl edit dynamographdeployment dynamo-lab -n dynamo-lab
# Change "ttft":2000 → "ttft":5 in the planner args
```

---

## Exercise 7 — Stop load and watch the Planner go idle

Stop the load generator (Ctrl+C or wait for it to finish). Watch the planner log:

```
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
5. **SLA targets are TTL + ITL** — these map to the user-facing experience: time until the first token appears, and smoothness of streaming

---

## Reference: Planner log messages

| Log message | Meaning |
|---|---|
| `New throughput adjustment interval started!` | Start of a 30-second scaling cycle |
| `Observed num_req: X` | Requests seen in the last interval from Prometheus |
| `Prefill calculation: X / Y = Z` | demand / capacity = workers needed |
| `Scaling to Z prefill workers` | Planner is writing a new replica count |
| `Metrics contain None or NaN` | No active traffic, scaling skipped |
| `Could not read GPU counts from DGD` | Falling back to CLI-configured GPU counts (normal for mocker) |
