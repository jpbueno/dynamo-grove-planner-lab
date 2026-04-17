# Dynamo Grove & Planner Lab — Setup Guide

---

## Your Environment

Your Brev instance is **fully provisioned** — the setup script ran automatically when the instance was created. Everything is ready.

**What's running:**

- A **single-node Kubernetes cluster** (kubeadm, v1.32)
- The **Dynamo platform** (operator, etcd, NATS) installed via NGC Helm charts
- **Four mock inference pods** — frontend, planner, prefill worker, decode worker
- **Prometheus** monitoring with frontend scrape config
- An **in-cluster Docker registry** with the mocker image

---

## Step 1 — Connect to Your Instance

You will receive a Brev launchable link from the instructor. Click **Deploy**, wait for the build to complete, then connect:

```bash
brev shell <your-instance-name>
```

Or use direct SSH if provided with a hostname.

---

## Step 2 — Verify the Environment

Run this quick check:

```bash
kubectl get pods -n dynamo-lab
```

You should see all four pods in `Running` / `1/1 Ready`:

```
NAME                                        READY   STATUS    RESTARTS   AGE
dynamo-lab-decodeworker-xxxxx-xxxxx         1/1     Running   0          ...
dynamo-lab-frontend-xxxxx-xxxxx             1/1     Running   0          ...
dynamo-lab-planner-xxxxx-xxxxx              1/1     Running   0          ...
dynamo-lab-prefillworker-xxxxx-xxxxx        1/1     Running   0          ...
```

---

## Step 3 — Smoke Test

```bash
# 1. Frontend responds to inference requests
FRONTEND_IP=$(kubectl get svc dynamo-lab-frontend -n dynamo-lab -o jsonpath='{.spec.clusterIP}')
echo "--- Frontend ---"
curl -s http://$FRONTEND_IP:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"nvidia/Llama-3.1-8B-Instruct-FP8","prompt":"hello","max_tokens":10,"stream":false}' \
  | jq '.usage'

# 2. Grove resources exist
echo "--- Grove ---"
kubectl get podcliquesets,podcliques,podgangs -n dynamo-lab

# 3. Planner control loop is running
echo "--- Planner ---"
kubectl logs -n dynamo-lab -l nvidia.com/dynamo-component-type=planner --tail=3

# 4. Prometheus is scraping the frontend
echo "--- Prometheus ---"
PROM_IP=$(kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus \
  -o jsonpath='{.spec.clusterIP}')
curl -s "http://$PROM_IP:9090/api/v1/query" \
  --data-urlencode 'query=up{job="dynamo-frontend"}' \
  | jq '.data.result | length'
```

**Expected results:**
1. JSON with `prompt_tokens` and `completion_tokens`
2. One PodCliqueSet, four PodCliques, one PodGang
3. Planner logs showing `New throughput adjustment interval started!`
4. `1` (Prometheus found one scrape target)

If all four pass, you are ready for the exercises.

---

## Lab Exercises

```bash
cat ~/dynamo-lab/grove-exercise.md      # Exercise 1: How the operator manages the pipeline
cat ~/dynamo-lab/planner-exercise.md    # Exercise 2: SLA-driven autoscaling
```

---

## Quick Reference

| Resource | How to find it |
|---|---|
| Frontend URL | `kubectl get svc dynamo-lab-frontend -n dynamo-lab -o jsonpath='{.spec.clusterIP}'` |
| Prometheus URL | `kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus -o jsonpath='{.spec.clusterIP}'` (port 9090) |
| Lab files | `~/dynamo-lab/` |
| Load generator | `python3 ~/dynamo-lab/load-gen.py --rps 5 --duration 90` |

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Planner logs: `Metrics contain None or NaN` | Normal when idle — resolves once you run the load generator |
| Load generator: `Connection refused` | Pass the frontend URL explicitly: `python3 load-gen.py --url http://$FRONTEND_IP:8000` |
| Prometheus check returns `0` | Wait 1-2 minutes for Prometheus to discover the target, then retry |
| Pod in `CrashLoopBackOff` | Check logs: `kubectl logs -n dynamo-lab <pod-name>` — contact the instructor |
