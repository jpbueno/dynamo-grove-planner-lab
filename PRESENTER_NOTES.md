# Dynamo Grove & Planner — Presenter Notes

**Audience level:** 200 — knows K8s basics (pods, deployments, HPA, services), doesn't know GPU-specific scheduling or Dynamo internals.

---

## Tab 0 — What AI Inference Demands from Kubernetes

### K8s Gaps subtab

"Alright, let's start with why we're here. Kubernetes was built for stateless web services — and it's really good at that. But LLM inference is fundamentally different, and K8s has some real gaps when you try to run it."

"First — **no multi-pod scheduling**. When you deploy a disaggregated inference pipeline, you have a frontend, prefill workers, decode workers — they all need GPUs at the same time. If three out of four components get GPUs and the fourth doesn't, you have three GPUs sitting idle burning money. K8s doesn't natively schedule groups of pods together."

"Second — **no topology awareness**. LLM serving moves a lot of data between GPUs, especially KV cache. If your pods land on GPUs connected by NVLink, that transfer is fast. If they end up on different nodes going over Ethernet, you've just introduced a massive latency penalty in the critical path."

"Third — **HPA scales on CPU metrics**. Your inference SLA isn't about CPU utilization. It's about TTFT — time to first token — and ITL — inter-token latency. Milliseconds. HPA doesn't know how to derive GPU count from those."

"Fourth — **no startup ordering**. In a pipeline, the frontend needs to be up before workers register with it. Prefill needs to be ready before decode tries to connect. Without ordering, you get crash loops on every deploy."

### Why It Matters subtab

"So what happens in practice without these?"

"Without gang scheduling — partial deploys. GPUs allocated but doing nothing. Direct cost impact."

"Without topology awareness — KV cache goes over the slow path. Your P99 latency blows up. And if both replicas land on the same node, you've lost HA entirely."

"Without SLA-aware scaling — HPA can't turn TTFT and ITL targets into a GPU count. You're either over-provisioned and wasting money, or under-provisioned and breaching SLAs."

### The Fix subtab

"Here's what this actually looks like when you solve these problems. These numbers are from Alibaba running Dynamo in production:"

- **80% fewer TTFT SLA breaches**
- **5% fewer GPUs for the same workload** — that's direct cost savings
- **30x throughput increase**
- **1 YAML to deploy** the whole thing

"Two components make this happen: **Grove** handles orchestration and placement. **Planner** handles SLA-driven autoscaling. Let's start with Grove."

---

## Tab 1 — Grove

### Opening

"The analogy we use is an airport control tower. Grove doesn't build the planes — it decides gate assignments and coordinates takeoffs so nothing collides on the runway."

"In practice, Grove is a single CRD called `PodCliqueSet` that replaces the mess of StatefulSets, manual affinity rules, PodAntiAffinity, and init containers you'd otherwise need."

### Features subtab

"Six core capabilities. I'll focus on the ones that matter most."

"**Gang scheduling** — all components of your pipeline land together, or none of them do. No more partial deploys with idle GPUs."

"**Topology-aware placement** — within a replica, everything is packed on GPUs connected by NVLink for fast data movement. Across replicas, they're spread across different nodes for high availability."

"**Startup ordering** — pods come up in the right sequence. Frontend first, then workers register with it. Prefill ready before decode tries to connect."

"**Smart rolling updates** — it updates a whole replica at a time, not random individual pods. You never end up in a broken mid-state during a rollout."

### Building Blocks subtab

"Three layers, bottom up."

"**PodCliques** — the base unit. Pods with the same role and same template. Your frontend pods are a PodClique. Your prefill workers are a PodClique. Each one has a replica count and a `minAvailable` — the minimum needed for the pipeline to function."

Walk through the diagram:

- Frontend: replicas=2, minAvailable=1
- PLeader: replicas=1, minAvailable=1
- PWorker: replicas=3, minAvailable=2
- DLeader: replicas=1, minAvailable=1
- DWorker: replicas=4, minAvailable=3

"**ScalingGroups** — PodCliques that need to scale together. Your prefill phase is one ScalingGroup — Frontend + PLeader + PWorker. Your decode phase is another — DLeader + DWorker."

"**PodCliqueSet** — the top-level CRD that wraps everything. One manifest. Gang scheduling, topology rules, autoscaling constraints — all expressed in one object."

### Topology subtab

"Two placement rules to remember."

"**Within a replica — pack.** All components on the same NVLink domain so KV cache and tensor data move fast."

"**Across replicas — spread.** Different nodes, different failure domains. You don't want one node failure to take out all your serving capacity."

"MNNVL — Multi-Node NVLink — extends this further. It's GPU-to-GPU communication across nodes over an RDMA fabric. That's how tensor parallel shards can span multiple servers while still getting NVLink-class bandwidth. Grove knows how to express and enforce those constraints."

---

## Tab 2 — Planner

### Opening

"Planner is the thermostat. You set the temperature — 50ms TTFT, 10ms ITL — and Planner continuously measures, predicts, and adjusts the GPU count to maintain it. After setup, you don't touch it."

### Two Phases subtab

"Two phases. This is the most important split to understand."

"**Phase 1 — Profile Once.** Before you take any live traffic, you run offline profiling. Planner benchmarks your specific model at different tensor parallel configs and batch sizes. The output is a capacity model: at this request rate, with this SLA, you need N prefill GPUs and M decode GPUs."

"**Phase 2 — Scale Forever.** At runtime, every adjustment interval — 20 seconds by default — Planner queries Prometheus, runs a load predictor, looks up the capacity model, and either scales up or down."

"The key insight: this is **model-specific profiling** driving the scaling decisions. Not generic CPU metrics. That's why it's more accurate than HPA."

### Pre-Deployment Profiling subtab

Point to the charts:

"These charts show profiling output. Left is prefill performance — TTFT on the X axis, throughput on the Y axis, plotted across different tensor parallel configurations: TP1, TP2, TP4, TP8. The dashed red line is your TTFT target at 50ms."

"Right chart is the same thing for decode — ITL on the X axis. Target at 5ms."

"Planner picks the configuration that meets your SLA targets at maximum throughput. Not guesswork — data."

### Planner Control Loop subtab

Use the animated stepper, walk each step:

1. **Query Prometheus** — "It pulls request rate, P99 TTFT and ITL, batch sizes, queue depths, and KV cache load. Full picture of how the system is actually performing."

2. **Correction Factors** — "This is the clever part. It computes actual latency divided by profiled latency. If the ratio is above 1.0, you're running hotter than profiling predicted — scale up. Below 1.0, maybe prefix caching is helping — scale down. This bridges the gap between offline profiling and real-world conditions."

3. **Predict Load** — "It doesn't just react to current state. It forecasts what load will look like in the next interval so it can pre-scale."

4. **Calc Replicas** — "Maps the predicted load onto the offline capacity model. 'This load needs N prefill GPUs and M decode GPUs to stay within SLA.'"

5. **Constraints** — "Applies your guardrails. `--max-gpu-budget` is a hard ceiling — it will never exceed it. `--min-endpoint` is the floor — it will never scale to zero."

6. **PATCH DGD** — "Writes the new replica count to the DynamoGraphDeploymentScalingAdapter, which updates the DGD. This is how Planner talks to Grove."

7. **Reconcile** — "Grove picks up the DGD change, adjusts PodCliques and PodGangs, KAI Scheduler places new pods respecting topology constraints. Then the loop restarts."

### Load Predictors table

"Four predictors — pick based on your traffic pattern."

- **`constant`** — assumes next interval equals current load. Use for fixed-rate batch pipelines, demos, testing.
- **`arima`** — detects trends from historical data. Good for gradual ramps — a chatbot going from 10 to 200 req/s by noon.
- **`kalman`** — filters noise and tracks the real signal. Best for bursty, event-driven traffic — think breaking news causing a spike.
- **`prophet`** — learns seasonal patterns: daily, weekly, holidays. Perfect for enterprise workloads — your coding assistant that ramps every Monday morning at 9.

### Advanced subtab

"Two things worth calling out."

"**Graceful scale-down** — when Planner removes replicas, it doesn't just kill pods. Connection draining, KV cache drain, the works. `terminationDelay` defaults to 4 hours so long-running sequences aren't interrupted. Zero dropped requests."

"**Dynamic serving mode** — Planner can switch between disaggregated and aggregated serving on a per-request basis. It looks at KV cache transfer cost, queue wait time, and SLO headroom, and picks whichever mode is better for that specific request."

---

## Tab 3 — Planner + Grove Together

### Opening

"Here's how the two pieces connect. The short version: **Planner decides what** — how many GPU replicas per phase. **Grove decides where** — pod placement respecting topology. **Together they decide how** — Planner PATCHes the DGD, Grove reconciles, the cluster converges."

### End-to-End Flow subtab

Walk the 7 animated steps:

1. **Deploy DGDR** — "You write one manifest — the DynamoGraphDeploymentRequest. Your model, your hardware preferences, your SLA targets. That's all you author."

2. **Profile Model** — "Dynamo Operator kicks off AIPerf to benchmark your model. One-time step."

3. **Generate DGD** — "Operator produces the DynamoGraphDeployment — concrete replica counts, service specs, ConfigMaps with the profiling data."

4. **Create PodGangs** — "Grove reads the DGD and generates a PodCliqueSet with gang-scheduling constraints."

5. **Schedule Pods** — "KAI Scheduler places all pods atomically. Packed within NVLink domains, spread across nodes."

6. **Monitor & Scale** — "Planner's loop runs continuously. Prometheus metrics in, scaling decisions out."

7. **Reconcile** — "Grove adjusts PodCliques and PodGangs to match the new state. Topology constraints are enforced for the new pods too. Cycle repeats."

### Resource Chain subtab

"Here's who creates what."

"**You define: the DGDR.** That's your wish list — model, backend, SLA targets, hardware, search strategy."

"**The system generates: the DGD.** That's the execution plan — concrete replica counts, service specs, profiling data, RBAC."

"**Grove creates: PodCliqueSet, PodCliques, ScalingGroups, PodGangs.** You never write any of those by hand."

---

## Tab 4 — Live Demo

### Setup

"We're running Qwen3-0.6B on A100 GPUs. The Planner is configured with a 20-second adjustment interval, TTFT target of 50ms, ITL target of 10ms. We'll push 15 requests per second at it."

"Three things to watch: the **Grafana dashboard** for latency and throughput, the **Planner logs** for scaling decisions, and **k9s** for pod lifecycle."

### Running it

**Phase 1 — Heavy load:**

"I'm firing 15 req/s at the cluster. Watch TTFT on Grafana — it's going to climb above the 50ms target. In the Planner logs, you'll see the correction factor go above 1.0."

**Phase 2 — Scale-up:**

"Within one to two adjustment intervals — 20 to 40 seconds — Planner PATCHes the DGD with a higher replica count. Grove creates a new PodGang. Watch k9s — you'll see the new pod go from Pending to Running."

"Once that replica joins the serving pool, TTFT drops back under 50ms. The correction factor settles back around 1.0."

**Phase 3 — Scale-down:**

"Now I'm stopping traffic. Correction factor drops below 1.0. After sustained low load, Planner scales down. Graceful termination — connection draining — no dropped requests."

### If something breaks

"Demos are honest. If it breaks, the Planner logs are the authoritative source — they show the exact correction factor, predicted load, and replica math behind every decision."

### Accordions to reference if asked

- **DGDR YAML** — show briefly if someone asks what the input manifest looks like
- **Demo Override Flags** — command-line parameters used for the demo
- **Grafana PromQL Queries** — TTFT P99, ITL P99, request rate, active GPU replicas
- **Key Files in the Repo** — file listing for anyone who wants to dig into the code

---

## Tab 5 — Resources (Closing & Audience Pivots)

Use this to tailor your closing based on who's in the room.

### CTO / VP Engineering

"GPU costs are your biggest AI infrastructure line item. Planner gives you SLA guarantees while cutting waste. Alibaba saw 80% fewer TTFT breaches with 5% fewer GPUs — at GPU prices, that's real money."

Pre-empt objections:

- "Too complex?" → One YAML — the DGDR. System generates everything else.
- "Lock-in?" → Open source, runs on any K8s cluster.
- "Production-ready?" → Running in production at Alibaba.

### Infra / Platform

"Grove replaces the StatefulSet + manual affinity + init container mess with one PodCliqueSet CRD. Gang scheduling, topology constraints, startup ordering — all built in."

Pre-empt objections:

- "Another CRD?" → It replaces 3 to 4 resources you're managing manually today.
- "Scheduler conflicts?" → Works alongside kube-scheduler; KAI Scheduler is the extensible layer.
- "Monitoring?" → Native Prometheus metrics, drops into existing dashboards.

### ML Engineers

"Planner doesn't guess. It uses your model's actual profiling data — batch size curves, TTFT and ITL across different TP configs. Set your targets, it handles the rest. Dry-run mode available if you want to validate before it touches anything."

Pre-empt objections:

- "Profiling overhead?" → One-time offline step. Re-profile in minutes after model updates.
- "vLLM only?" → Also supports TensorRT-LLM.

### App Developers

"You don't need to know GPUs exist. Set SLA targets, deploy, same OpenAI-compatible endpoint whether you're behind 1 GPU or 8. Latency guarantees make real-time AI features viable."

Pre-empt objections:

- "Scales too slowly?" → 20s default, configurable down to 5s.
- "Affects my API?" → Same endpoint, zero-downtime scaling.
- "Cost?" → Scales down automatically when load drops. Pay for what you use.

---

## Presenter Cheat Sheet

| Common question | Where to find the answer |
|---|---|
| "What does the DGDR look like?" | Tab 4 → DGDR YAML accordion |
| "What metrics does Planner use?" | Tab 2 → Advanced → Metrics Beyond TTFT/ITL |
| "What's the difference between DGDR and DGD?" | Tab 5 → FAQ section |
| "What is TTFT / ITL?" | Tab 5 → Glossary |
| "What's a PodClique?" | Tab 1 → Building Blocks, or Tab 5 → Glossary |
| "How fast does it scale?" | Tab 4 → demo shows ~20-40s end-to-end |

**Pacing tip:** The correction factor explanation (Planner loop step 2) is the most abstract concept. Slow down there — it's the bridge between offline profiling and real-world scaling decisions.

**Demo tip:** k9s showing pods go Pending → Running in real time lands harder than any slide. Keep it visible.
