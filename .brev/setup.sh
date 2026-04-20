#!/usr/bin/env bash
# =============================================================================
# .brev/setup.sh — Brev launchable setup for the Dynamo Grove & Planner lab
#
# Runs automatically after Brev provisions a Single-node Kubernetes instance.
# Kubernetes, kubectl, containerd, and Docker are already available.
#
# Required Brev environment variable:
#   NGC_API_KEY — for pulling the Dynamo operator image from nvcr.io
# =============================================================================
set -euo pipefail

###############################################################################
# Configuration
###############################################################################
DYNAMO_VERSION="${DYNAMO_VERSION:-0.9.0}"
DYNAMO_NAMESPACE="${DYNAMO_NAMESPACE:-dynamo}"
NGC_HELM_BASE="https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts"
LAB_DIR="$HOME/dynamo-lab"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

###############################################################################
# Helpers
###############################################################################
info()    { printf '\033[1;34m▸ %s\033[0m\n' "$*"; }
ok()      { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
warn()    { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
fail()    { printf '\033[1;31m✘ %s\033[0m\n' "$*"; exit 1; }
section() { printf '\n\033[1;36m══════════════════════════════════════════════\033[0m\n'; printf '\033[1;36m  %s\033[0m\n' "$*"; printf '\033[1;36m══════════════════════════════════════════════\033[0m\n\n'; }

wait_for() {
  local label="$1" cmd="$2" tries="${3:-60}" delay="${4:-5}"
  info "Waiting: $label"
  for ((i=1; i<=tries; i++)); do
    if eval "$cmd" &>/dev/null; then ok "$label"; return 0; fi
    sleep "$delay"
  done
  fail "$label — timed out after $((tries * delay))s"
}

###############################################################################
# Pre-flight
###############################################################################
section "Pre-flight Checks"

# Verify K8s is up (Brev provides this in Single-node K8s mode)
wait_for "Kubernetes API reachable" "kubectl get nodes" 30 5

# Untaint control-plane if needed (Brev may or may not do this)
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

NODE_NAME="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
ok "Cluster ready: $NODE_NAME"

# NGC API key
if [[ -z "${NGC_API_KEY:-}" ]]; then
  fail "NGC_API_KEY environment variable is not set. Add it in Brev launchable settings."
fi

###############################################################################
# Install system dependencies
###############################################################################
section "System Dependencies"

info "Installing packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq jq python3-pip 2>/dev/null || true

pip3 install --break-system-packages aiohttp 2>/dev/null || pip3 install aiohttp
ok "Dependencies installed"

###############################################################################
# Helm
###############################################################################
section "Helm"

if command -v helm &>/dev/null; then
  ok "Helm already installed"
else
  info "Installing Helm 3..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
  ok "Helm installed"
fi

###############################################################################
# Dynamo Platform (Operator, Grove, KAI Scheduler)
###############################################################################
section "Dynamo Platform (v${DYNAMO_VERSION})"

if kubectl get crd dynamographdeployments.nvidia.com &>/dev/null; then
  ok "Dynamo CRDs already present — skipping"
else
  CRDS_TGZ="/tmp/dynamo-crds-${DYNAMO_VERSION}.tgz"
  PLATFORM_TGZ="/tmp/dynamo-platform-${DYNAMO_VERSION}.tgz"

  # NGC image-pull secret
  kubectl create namespace "$DYNAMO_NAMESPACE" 2>/dev/null || true
  kubectl create secret docker-registry nvcr-imagepullsecret \
    --docker-server=nvcr.io \
    --docker-username='$oauthtoken' \
    --docker-password="$NGC_API_KEY" \
    --namespace "$DYNAMO_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  ok "NGC image-pull secret created"

  # Dynamo CRDs
  info "Installing Dynamo CRDs..."
  curl -fSL "${NGC_HELM_BASE}/dynamo-crds-${DYNAMO_VERSION}.tgz" -o "$CRDS_TGZ"
  helm upgrade --install dynamo-crds "$CRDS_TGZ" --namespace default --wait
  ok "CRDs installed"

  # Platform chart — download and pre-install Grove/KAI CRDs
  info "Downloading Dynamo platform chart..."
  curl -fSL "${NGC_HELM_BASE}/dynamo-platform-${DYNAMO_VERSION}.tgz" -o "$PLATFORM_TGZ"

  EXTRACT_DIR="/tmp/dynamo-platform-extract"
  rm -rf "$EXTRACT_DIR" && mkdir -p "$EXTRACT_DIR"
  tar xzf "$PLATFORM_TGZ" -C "$EXTRACT_DIR"

  KAI_CRDS="$EXTRACT_DIR/dynamo-platform/charts/kai-scheduler/crds"
  [[ -d "$KAI_CRDS" ]] && kubectl apply -f "$KAI_CRDS/" && ok "KAI Scheduler CRDs applied"

  GROVE_CRDS="$EXTRACT_DIR/dynamo-platform/charts/grove-charts/crds"
  [[ -d "$GROVE_CRDS" ]] && kubectl apply --server-side -f "$GROVE_CRDS/" && ok "Grove CRDs applied"
  rm -rf "$EXTRACT_DIR"

  # Install platform
  info "Installing Dynamo platform..."
  helm upgrade --install dynamo-platform "$PLATFORM_TGZ" \
    --namespace "$DYNAMO_NAMESPACE" \
    --set "dynamo-operator.webhook.enabled=false" \
    --set "grove.enabled=true" \
    --set "kai-scheduler.enabled=true" \
    --wait --timeout 300s
  rm -f "$CRDS_TGZ" "$PLATFORM_TGZ"

  wait_for "Dynamo CRDs registered" "kubectl get crd dynamographdeployments.nvidia.com"
  ok "Dynamo platform installed"
fi

###############################################################################
# In-cluster Docker Registry
###############################################################################
section "In-Cluster Registry"

if kubectl get deploy/registry -n kube-system &>/dev/null; then
  ok "Registry already exists"
else
  info "Deploying registry..."
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
      nodeName: ${NODE_NAME}
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
fi

wait_for "Registry ready" "kubectl rollout status deploy/registry -n kube-system --timeout=5s"
REGISTRY_IP="$(kubectl get svc registry -n kube-system -o jsonpath='{.spec.clusterIP}')"
info "Registry: $REGISTRY_IP:5000"

# Configure containerd to trust the registry
sudo mkdir -p "/etc/containerd/certs.d/${REGISTRY_IP}:5000"
sudo tee "/etc/containerd/certs.d/${REGISTRY_IP}:5000/hosts.toml" > /dev/null <<EOF
server = "http://${REGISTRY_IP}:5000"
[host."http://${REGISTRY_IP}:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF

# Ensure containerd has config_path enabled
if ! sudo grep -q 'config_path.*certs.d' /etc/containerd/config.toml 2>/dev/null; then
  sudo sed -i '/\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\]/a\      config_path = "/etc/containerd/certs.d"' /etc/containerd/config.toml 2>/dev/null || true
fi

sudo systemctl restart containerd
wait_for "Node Ready after containerd restart" "kubectl get nodes | grep -qw Ready" 30 5
ok "Registry up at $REGISTRY_IP:5000"

###############################################################################
# Lab Files & Mocker Image
###############################################################################
section "Lab Files & Mocker Image"

mkdir -p "$LAB_DIR"
cp -r "$SCRIPT_DIR/dynamo-lab"/. "$LAB_DIR"/
chmod +x "$LAB_DIR/load-gen.py" 2>/dev/null || true
ok "Lab files at $LAB_DIR"

info "Building dynamo-mocker:1.0.0..."
docker build -t "${REGISTRY_IP}:5000/dynamo-mocker:1.0.0" "$LAB_DIR/build/"
docker push "${REGISTRY_IP}:5000/dynamo-mocker:1.0.0"

wait_for "Image in registry" \
  "curl -sf http://${REGISTRY_IP}:5000/v2/_catalog | grep -q dynamo-mocker"
ok "dynamo-mocker:1.0.0 pushed"

###############################################################################
# Patch Deployment Manifest
###############################################################################
MANIFEST="$LAB_DIR/dynamo-lab-deployment.yaml"
sed -i "s|10\.100\.11\.173:5000|${REGISTRY_IP}:5000|g" "$MANIFEST"
ok "Manifest patched with registry IP"

###############################################################################
# Prometheus
###############################################################################
section "Prometheus"

if kubectl get deploy -n monitoring prometheus-kube-prometheus-prometheus &>/dev/null; then
  ok "Prometheus already deployed"
else
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update

  kubectl create namespace monitoring 2>/dev/null || true

  cat > /tmp/prometheus-values.yaml <<'PROMEOF'
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
PROMEOF

  helm install prometheus prometheus-community/prometheus \
    -n monitoring -f /tmp/prometheus-values.yaml --wait --timeout 300s
  rm -f /tmp/prometheus-values.yaml
  ok "Prometheus installed"
fi

###############################################################################
# Deploy Lab Workload
###############################################################################
section "Deploy Lab Workload"

kubectl create namespace dynamo-lab 2>/dev/null || true
kubectl apply -f "$MANIFEST" -n dynamo-lab

info "Waiting for lab pods..."
wait_for "Frontend ready" \
  "kubectl get pods -n dynamo-lab -l nvidia.com/dynamo-component=Frontend -o jsonpath='{.items[0].status.phase}' | grep -q Running" 60 5
wait_for "Planner ready" \
  "kubectl get pods -n dynamo-lab -l nvidia.com/dynamo-component=Planner -o jsonpath='{.items[0].status.phase}' | grep -q Running" 60 5
wait_for "PrefillWorker ready" \
  "kubectl get pods -n dynamo-lab -l nvidia.com/dynamo-component=PrefillWorker -o jsonpath='{.items[0].status.phase}' | grep -q Running" 60 5
wait_for "DecodeWorker ready" \
  "kubectl get pods -n dynamo-lab -l nvidia.com/dynamo-component=DecodeWorker -o jsonpath='{.items[0].status.phase}' | grep -q Running" 60 5
ok "All 4 lab pods running"

###############################################################################
# Smoke Tests
###############################################################################
section "Smoke Tests"

PASS=0
TOTAL=4

FRONTEND_IP="$(kubectl get svc dynamo-lab-frontend -n dynamo-lab -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")"

# 1. Frontend responds
RESPONSE="$(curl -sf --max-time 10 "http://${FRONTEND_IP}:8000/v1/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"nvidia/Llama-3.1-8B-Instruct-FP8","prompt":"hello","max_tokens":10,"stream":false}' 2>/dev/null || echo "")"
if echo "$RESPONSE" | jq -e '.usage' &>/dev/null; then
  ok "Frontend responds"; PASS=$((PASS + 1))
else warn "Frontend not responding"; fi

# 2. Planner active
PLANNER_LOG="$(kubectl logs -n dynamo-lab -l nvidia.com/dynamo-component=Planner --tail=20 2>/dev/null || echo "")"
if echo "$PLANNER_LOG" | grep -qi "adjustment\|started\|interval"; then
  ok "Planner active"; PASS=$((PASS + 1))
else warn "Planner not active yet"; fi

# 3. Grove resources
PCS="$(kubectl get podcliquesets -n dynamo-lab --no-headers 2>/dev/null | wc -l)"
PC="$(kubectl get podcliques -n dynamo-lab --no-headers 2>/dev/null | wc -l)"
if [[ "$PCS" -ge 1 && "$PC" -ge 1 ]]; then
  ok "Grove: ${PCS} PodCliqueSet(s), ${PC} PodClique(s)"; PASS=$((PASS + 1))
else warn "Grove resources incomplete"; fi

# 4. Prometheus scraping
PROM_IP="$(kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")"
TARGETS="$(curl -sf --max-time 10 "http://${PROM_IP}:80/api/v1/query" \
  --data-urlencode 'query=up{job="dynamo-frontend"}' 2>/dev/null || echo "")"
TC="$(echo "$TARGETS" | jq -r '.data.result | length' 2>/dev/null || echo 0)"
if [[ "$TC" -ge 1 ]]; then
  ok "Prometheus scraping frontend"; PASS=$((PASS + 1))
else warn "Prometheus not scraping yet (may take a minute)"; fi

###############################################################################
# Done
###############################################################################
section "Setup Complete"

# Write a cheatsheet to the home directory for easy reference
cat > "$HOME/LAB_READY.txt" <<CHEAT
Dynamo Grove & Planner Lab — Ready!

  Lab files:    $LAB_DIR
  Frontend:     http://${FRONTEND_IP:-unknown}:8000
  Prometheus:   http://${PROM_IP:-unknown}:80
  Registry:     http://$REGISTRY_IP:5000

  Exercises:
    cat $LAB_DIR/lab-exercises.md

  Quick test:
    python3 $LAB_DIR/load-gen.py --url http://${FRONTEND_IP}:8000 --rps 5 --duration 90

  Smoke tests: $PASS/$TOTAL passed
CHEAT

echo ""
cat "$HOME/LAB_READY.txt"
echo ""

if [[ "$PASS" -eq "$TOTAL" ]]; then
  ok "All smoke tests passed — environment is ready!"
else
  warn "$((TOTAL - PASS)) test(s) pending — may resolve in 1-2 minutes"
fi
