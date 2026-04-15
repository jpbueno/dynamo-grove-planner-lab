# Dynamo Grove & Planner Lab — Setup Guide

**Complete these steps before the workshop so your environment is ready to go.**

---

## What You Get

You will receive SSH access to a **single Brev cloud instance** (4 vCPU / 16 GB RAM) that has:

- A **single-node Kubernetes cluster** (kubeadm, v1.33) with the control-plane untainted for workload scheduling
- The **Dynamo platform** (operator, Grove, KAI Scheduler) pre-installed via Helm
- `kubectl`, `docker`, `jq`, `helm`, and `python3` already available

---

## Step 1 — Connect to Your Instance

You will receive an SSH hostname from the instructor. Connect with:

```bash
ssh <your-instance>
```

Verify cluster access:

```bash
kubectl get nodes
```

You should see a single node in `Ready` state:

```
NAME              STATUS   ROLES           AGE   VERSION
<your-instance>   Ready    control-plane   ...   v1.33.x
```

Verify the Dynamo CRDs are installed:

```bash
kubectl get crd | grep dynamo
```

You should see `dynamographdeployments.nvidia.com` and several other Dynamo CRDs.

---

## Step 2 — Install Python Dependencies

The load generator used in the Planner exercise requires `aiohttp`:

```bash
pip install aiohttp
```

---

## Step 3 — Clone the Lab Files

```bash
cd ~
git clone https://gitlab-master.nvidia.com/jbuenosantan/dynamo-grove-planner-course.git
cp -r dynamo-grove-planner-course/dynamo-lab ~/dynamo-lab
```

Verify:

```bash
ls ~/dynamo-lab/
```

You should see:

```
build/
dynamo-lab-deployment.yaml
grove-exercise.md
load-gen.py
planner-exercise.md
setup-guide.md
```

---

## Step 4 — Deploy the In-Cluster Docker Registry

The mocker image needs to live in a registry the cluster can pull from. Since this is a single-node cluster, both the registry and all pods run on the same machine.

### 4a — Create the registry

```bash
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      containers:
      - name: registry
        image: registry:2
        ports:
        - containerPort: 5000
        env:
        - name: REGISTRY_STORAGE_DELETE_ENABLED
          value: "true"
      nodeName: $NODE_NAME
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: kube-system
spec:
  selector:
    app: registry
  ports:
  - port: 5000
    targetPort: 5000
EOF
```

Wait for the registry pod to start:

```bash
kubectl rollout status deploy/registry -n kube-system --timeout=60s
```

### 4b — Get the registry ClusterIP

```bash
REGISTRY_IP=$(kubectl get svc registry -n kube-system -o jsonpath='{.spec.clusterIP}')
echo "Registry: $REGISTRY_IP:5000"
```

### 4c — Configure containerd to trust the registry

```bash
sudo mkdir -p /etc/containerd/certs.d/$REGISTRY_IP:5000

sudo tee /etc/containerd/certs.d/$REGISTRY_IP:5000/hosts.toml > /dev/null <<EOF
server = "http://$REGISTRY_IP:5000"
[host."http://$REGISTRY_IP:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF

sudo systemctl restart containerd
```

Wait a few seconds for containerd to come back, then verify the node is Ready:

```bash
kubectl get nodes
```

---

## Step 5 — Build and Push the Mocker Image

```bash
REGISTRY_IP=$(kubectl get svc registry -n kube-system -o jsonpath='{.spec.clusterIP}')

cd ~/dynamo-lab/build
docker build -t $REGISTRY_IP:5000/dynamo-mocker:1.0.0 .
docker push $REGISTRY_IP:5000/dynamo-mocker:1.0.0
```

Verify the image is in the registry:

```bash
curl -s http://$REGISTRY_IP:5000/v2/_catalog
```

Expected: `{"repositories":["dynamo-mocker"]}`

---

## Step 6 — Update the Deployment Manifest

The deployment manifest contains a placeholder registry IP. Update it to match your cluster:

```bash
REGISTRY_IP=$(kubectl get svc registry -n kube-system -o jsonpath='{.spec.clusterIP}')

cd ~/dynamo-lab
sed -i "s|10.100.11.173:5000|$REGISTRY_IP:5000|g" dynamo-lab-deployment.yaml
```

Verify the image references are correct:

```bash
grep "image:" dynamo-lab-deployment.yaml
```

All four entries should show your `$REGISTRY_IP:5000/dynamo-mocker:1.0.0`.

---

## Step 7 — Install Prometheus

The Planner reads TTFT and ITL metrics from Prometheus. The scrape configuration below tells Prometheus how to find the Dynamo frontend pods.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring

cat <<'EOF' > /tmp/prometheus-values.yaml
alertmanager:
  enabled: false
kube-state-metrics:
  enabled: false
nodeExporter:
  enabled: false
prometheus-pushgateway:
  enabled: false
server:
  fullnameOverride: prometheus-kube-prometheus-prometheus
  service:
    type: ClusterIP
  extraScrapeConfigs: |
    - job_name: dynamo-frontend
      kubernetes_sd_configs:
      - role: pod
        namespaces:
          names: [dynamo-lab]
      relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_nvidia_com_dynamo_component_type]
        action: keep
        regex: frontend
      - source_labels: [__meta_kubernetes_pod_ip]
        target_label: __address__
        replacement: ${1}:8000
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
EOF

helm install prometheus prometheus-community/prometheus \
  -n monitoring -f /tmp/prometheus-values.yaml
```

Wait for Prometheus to be ready:

```bash
kubectl rollout status deploy/prometheus-kube-prometheus-prometheus -n monitoring --timeout=120s
```

---

## Step 8 — Create the Namespace and Deploy

```bash
kubectl create namespace dynamo-lab

kubectl apply -f ~/dynamo-lab/dynamo-lab-deployment.yaml -n dynamo-lab
```

Wait for all pods to start (takes 1-2 minutes):

```bash
kubectl get pods -n dynamo-lab -w
```

All four pods should reach `Running` / `1/1 Ready`:

```
NAME                                   READY   STATUS
dynamo-lab-0-decodeworker-xxxxx        1/1     Running
dynamo-lab-0-frontend-xxxxx            1/1     Running
dynamo-lab-0-planner-xxxxx             1/1     Running
dynamo-lab-0-prefillworker-xxxxx       1/1     Running
```

Press `Ctrl+C` once all four are running.

---

## Step 9 — Verify the Full Stack

Run the smoke test below. All four checks should pass:

```bash
# 1. Frontend responds to inference requests
FRONTEND_IP=$(kubectl get svc dynamo-lab-frontend -n dynamo-lab -o jsonpath='{.spec.clusterIP}')
echo "--- Frontend ---"
curl -s http://$FRONTEND_IP:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"nvidia/Llama-3.1-8B-Instruct-FP8","prompt":"hello","max_tokens":10,"stream":false}' \
  | jq '.usage'

# 2. Planner control loop is running
echo "--- Planner ---"
kubectl logs -n dynamo-lab -l nvidia.com/dynamo-component=Planner --tail=3

# 3. Grove resources exist
echo "--- Grove ---"
kubectl get podcliquesets,podcliques,podgangs -n dynamo-lab

# 4. Prometheus is scraping the frontend
echo "--- Prometheus ---"
PROM_IP=$(kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus \
  -o jsonpath='{.spec.clusterIP}')
curl -s "http://$PROM_IP:80/api/v1/query" \
  --data-urlencode 'query=up{job="dynamo-frontend"}' \
  | jq '.data.result | length'
```

**Expected results:**
1. JSON with `prompt_tokens` and `completion_tokens`
2. Planner logs showing `New throughput adjustment interval started!`
3. One PodCliqueSet, four PodCliques, one PodGang
4. `1` (Prometheus found one scrape target)

If all four pass, you are ready for the workshop.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ImagePullBackOff` on pods | Containerd can't reach registry — re-run Step 4c, verify `curl http://$REGISTRY_IP:5000/v2/_catalog` |
| Planner logs: `Metrics contain None or NaN` | Normal when idle — this means no traffic. It resolves once you run the load generator during the exercise |
| Load generator: `Connection refused` | Pass the correct frontend URL: `python3 load-gen.py --url http://$FRONTEND_IP:8000` |
| Prometheus check returns `0` | Scrape config may be wrong — verify `kubectl logs deploy/prometheus-kube-prometheus-prometheus -n monitoring` |
| `kubectl get podcliqueset` → `not found` | Dynamo CRDs not installed — contact the instructor |
| Pods stuck in `Pending` | Run `kubectl describe pod <name> -n dynamo-lab` — on a single node, check if the control-plane taint was removed |
| Node shows `NotReady` after Step 4c | Containerd is restarting — wait 10-15 seconds and check again |
