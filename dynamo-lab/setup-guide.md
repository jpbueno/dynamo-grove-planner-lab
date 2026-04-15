# Dynamo Grove & Planner Lab — Setup Guide

**Send to attendees 1-2 days before the workshop.**

---

## What You Get

You will receive SSH access to a Brev cloud instance that has:

- A **2-node Kubernetes cluster** (kubeadm, v1.33)
- The **Dynamo platform** (operator, Grove, KAI Scheduler) pre-installed via Helm
- `kubectl`, `docker`, `jq`, and `python3` already available

You need to complete the steps below **before the workshop** so the lab environment is ready to go.

---

## Step 1 — Connect to Your Instance

```bash
ssh cpu-k8s1
```

Verify cluster access:

```bash
kubectl get nodes
```

You should see two nodes in `Ready` state:

```
NAME       STATUS   ROLES           AGE   VERSION
cpu-k8s1   Ready    control-plane   ...   v1.33.x
cpu-k8s2   Ready    <none>          ...   v1.33.x
```

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
```

---

## Step 4 — Deploy the In-Cluster Docker Registry

The mocker image needs to live in a registry that the cluster can pull from.

### 4a — Create the registry

```bash
kubectl apply -f - <<'EOF'
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
      nodeName: cpu-k8s1
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

### 4b — Get the registry ClusterIP

```bash
REGISTRY_IP=$(kubectl get svc registry -n kube-system -o jsonpath='{.spec.clusterIP}')
echo "Registry: $REGISTRY_IP:5000"
```

### 4c — Configure containerd to trust the registry (run on BOTH nodes)

On **cpu-k8s1**:

```bash
sudo mkdir -p /etc/containerd/certs.d/$REGISTRY_IP:5000
sudo tee /etc/containerd/certs.d/$REGISTRY_IP:5000/hosts.toml <<EOF
server = "http://$REGISTRY_IP:5000"
[host."http://$REGISTRY_IP:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
sudo systemctl restart containerd
```

On **cpu-k8s2** (SSH from cpu-k8s1 or repeat from your local machine):

```bash
ssh cpu-k8s2 "sudo mkdir -p /etc/containerd/certs.d/$REGISTRY_IP:5000 && \
  sudo tee /etc/containerd/certs.d/$REGISTRY_IP:5000/hosts.toml <<EOF
server = \"http://$REGISTRY_IP:5000\"
[host.\"http://$REGISTRY_IP:5000\"]
  capabilities = [\"pull\", \"resolve\"]
  skip_verify = true
EOF
sudo systemctl restart containerd"
```

---

## Step 5 — Build and Push the Mocker Image

```bash
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

The deployment manifest references the registry IP. Update it to match your cluster:

```bash
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

The Planner reads metrics from Prometheus. Install it with Helm:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring

helm install prometheus prometheus-community/prometheus \
  -n monitoring \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false
```

Wait for Prometheus to be ready:

```bash
kubectl rollout status deploy -n monitoring --timeout=120s
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
NAME                                   READY   STATUS    RESTARTS   AGE
dynamo-lab-0-decodeworker-xxxxx        1/1     Running   0          ...
dynamo-lab-0-frontend-xxxxx            1/1     Running   0          ...
dynamo-lab-0-planner-xxxxx             1/1     Running   0          ...
dynamo-lab-0-prefillworker-xxxxx       1/1     Running   0          ...
```

---

## Step 9 — Update the Load Generator Endpoint

The load generator has a hardcoded frontend IP. Update it to match your cluster:

```bash
FRONTEND_IP=$(kubectl get svc dynamo-lab-frontend -n dynamo-lab -o jsonpath='{.spec.clusterIP}')
sed -i "s|http://10.110.107.86:8000|http://$FRONTEND_IP:8000|" ~/dynamo-lab/load-gen.py
echo "Frontend: http://$FRONTEND_IP:8000"
```

---

## Step 10 — Verify the Full Stack

Run a quick smoke test:

```bash
# 1. Frontend responds
FRONTEND_IP=$(kubectl get svc dynamo-lab-frontend -n dynamo-lab -o jsonpath='{.spec.clusterIP}')
curl -s http://$FRONTEND_IP:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"nvidia/Llama-3.1-8B-Instruct-FP8","prompt":"hello","max_tokens":10,"stream":false}' \
  | jq '.usage'

# 2. Planner is running its control loop
kubectl logs -n dynamo-lab -l nvidia.com/dynamo-component=Planner --tail=5

# 3. Grove resources exist
kubectl get podcliquesets,podcliques,podgangs -n dynamo-lab

# 4. Prometheus is scraping
PROM_IP=$(kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus -o jsonpath='{.spec.clusterIP}')
curl -s "http://$PROM_IP:80/api/v1/query" \
  --data-urlencode 'query=up{job=~".*dynamo.*"}' | jq '.data.result | length'
```

If all four checks pass, you are ready for the workshop.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ImagePullBackOff` on pods | Registry or containerd config issue — re-run Step 4c and verify `curl http://$REGISTRY_IP:5000/v2/_catalog` |
| Planner logs show `Could not connect to Prometheus` | Prometheus not ready — check `kubectl get pods -n monitoring` |
| Load generator returns `Connection refused` | Frontend service IP changed — re-run Step 9 |
| `kubectl get podcliqueset` returns `not found` | Dynamo CRDs not installed — contact the instructor |
| Pods stuck in `Pending` | Check `kubectl describe pod <name> -n dynamo-lab` — likely a scheduling issue |
