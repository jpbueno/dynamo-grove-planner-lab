#!/usr/bin/env bash
# =============================================================================
# setup-node.sh — Single-step setup for the Dynamo Grove & Planner hands-on lab
#
# Installs a single-node Kubernetes cluster, the Dynamo platform, and all lab
# prerequisites on a fresh Ubuntu 22.04+ instance.
#
# Usage:
#   sudo NGC_API_KEY=<your-key> bash setup-node.sh
#
# Get an NGC API key at https://org.ngc.nvidia.com/setup/api-key
#
# Configurable via environment variables (see defaults below).
# =============================================================================
set -euo pipefail

###############################################################################
# Configuration — override any of these before running
###############################################################################
KUBE_VERSION="${KUBE_VERSION:-1.32}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
DYNAMO_VERSION="${DYNAMO_VERSION:-0.9.0}"
DYNAMO_NAMESPACE="${DYNAMO_NAMESPACE:-dynamo}"
NGC_HELM_BASE="https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts"
# Place lab files in the calling user's home (not root's) so they're accessible
if [[ -n "${SUDO_USER:-}" ]]; then
  _SUDO_HOME="$(eval echo "~${SUDO_USER}")"
  LAB_DIR="${LAB_DIR:-${_SUDO_HOME}/dynamo-lab}"
else
  LAB_DIR="${LAB_DIR:-$HOME/dynamo-lab}"
fi

# Resolve the directory this script lives in (dynamo-lab/ inside the repo)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
# Pre-flight checks
###############################################################################
section "Pre-flight Checks"

[[ $EUID -eq 0 ]] || fail "This script must be run as root: sudo bash $0"
[[ -f /etc/os-release ]] && . /etc/os-release || fail "Only Ubuntu/Debian is supported"
[[ "$ID" == "ubuntu" || "$ID" == "debian" ]] || warn "Untested distro: $ID — proceeding anyway"

ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
ok "OS: $PRETTY_NAME ($ARCH)"

###############################################################################
# Phase 1 — System packages
###############################################################################
section "Phase 1: System Packages"

info "Updating apt and installing base packages..."
apt-get update -qq
apt-get install -y -qq \
  apt-transport-https ca-certificates curl gnupg lsb-release \
  jq python3 python3-pip git socat conntrack ipvsadm

info "Installing Python dependencies..."
pip3 install --break-system-packages aiohttp 2>/dev/null || pip3 install aiohttp
ok "System packages installed"

###############################################################################
# Phase 2 — Container runtime (containerd + Docker CLI)
###############################################################################
section "Phase 2: Container Runtime"

if command -v docker &>/dev/null && command -v containerd &>/dev/null; then
  ok "Docker CLI and containerd already installed — skipping"
else
  info "Installing containerd and Docker CLI..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq containerd.io docker-ce-cli docker-buildx-plugin
  ok "Docker CLI and containerd installed"
fi

info "Configuring containerd for Kubernetes..."
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# Enable SystemdCgroup (required for kubeadm)
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Enable registry config_path so hosts.toml files are respected.
# containerd v2 uses io.containerd.cri.v1.images.registry;
# containerd v1 uses io.containerd.grpc.v1.cri.registry.
# Set config_path on the FIRST empty config_path line under a registry section.
REGISTRY_LINE=$(grep -n "config_path = ''" /etc/containerd/config.toml | head -1 | cut -d: -f1)
if [[ -n "$REGISTRY_LINE" ]]; then
  sed -i "${REGISTRY_LINE}s|config_path = ''|config_path = '/etc/containerd/certs.d'|" /etc/containerd/config.toml
fi
mkdir -p /etc/containerd/certs.d

systemctl restart containerd
systemctl enable containerd
ok "containerd configured with SystemdCgroup and registry config_path"

###############################################################################
# Phase 3 — Kubernetes (kubeadm single-node)
###############################################################################
section "Phase 3: Kubernetes ${KUBE_VERSION} (single-node)"

# Kernel modules
info "Loading kernel modules..."
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# Sysctl
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system -q

# Disable swap
swapoff -a
sed -i '/\sswap\s/d' /etc/fstab

if command -v kubeadm &>/dev/null; then
  ok "kubeadm already installed — skipping package install"
else
  info "Installing kubeadm, kubelet, kubectl..."
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/Release.key" \
    | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
    https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

  apt-get update -qq
  apt-get install -y -qq kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
  ok "Kubernetes packages installed"
fi

# Initialize cluster if not already done
if [[ -f /etc/kubernetes/admin.conf ]]; then
  ok "Cluster already initialized — skipping kubeadm init"
else
  info "Initializing single-node cluster (pod CIDR: $POD_CIDR)..."
  kubeadm init --pod-network-cidr="$POD_CIDR"
  ok "Cluster initialized"
fi

# Set up kubeconfig for root
export KUBECONFIG=/etc/kubernetes/admin.conf
mkdir -p "$HOME/.kube"
cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

# Set up kubeconfig for the sudo caller if different
if [[ -n "${SUDO_USER:-}" ]]; then
  USER_HOME="$(eval echo "~${SUDO_USER}")"
  mkdir -p "${USER_HOME}/.kube"
  cp -f /etc/kubernetes/admin.conf "${USER_HOME}/.kube/config"
  chown "$(id -u "$SUDO_USER"):$(id -g "$SUDO_USER")" "${USER_HOME}/.kube/config"
fi

# kubectl autocomplete and alias for all users
info "Configuring kubectl autocomplete and alias..."
kubectl completion bash > /etc/bash_completion.d/kubectl
cat >> /etc/profile.d/kubectl-alias.sh <<'KEOF'
alias k=kubectl
complete -o default -F __start_kubectl k
KEOF
chmod +x /etc/profile.d/kubectl-alias.sh
# Also apply to root's bashrc
grep -q "alias k=kubectl" "$HOME/.bashrc" 2>/dev/null || echo 'alias k=kubectl' >> "$HOME/.bashrc"
if [[ -n "${SUDO_USER:-}" ]]; then
  USER_HOME="$(eval echo "~${SUDO_USER}")"
  grep -q "alias k=kubectl" "${USER_HOME}/.bashrc" 2>/dev/null || echo 'alias k=kubectl' >> "${USER_HOME}/.bashrc"
fi

# Untaint control-plane so workloads can schedule on this single node
info "Untainting control-plane node..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

# Install CNI (Flannel)
info "Installing Flannel CNI..."
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

wait_for "Node is Ready" "kubectl get nodes | grep -qw Ready"

# Install local-path StorageClass (kubeadm ships without one, needed for etcd/NATS PVCs)
info "Installing local-path StorageClass provisioner..."
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

ok "Single-node Kubernetes cluster is up"

###############################################################################
# Phase 4 — Helm
###############################################################################
section "Phase 4: Helm"

if command -v helm &>/dev/null; then
  ok "Helm already installed — skipping"
else
  info "Installing Helm 3..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  ok "Helm installed"
fi

###############################################################################
# Phase 5 — Dynamo platform (Operator + Grove + KAI Scheduler)
#
# Charts are pulled from the NGC Helm registry:
#   https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/
#
# Grove and KAI Scheduler are enabled so students can interact with
# PodCliqueSets, PodCliques, and PodGangs. On CPU-only nodes, we advertise
# fake GPU resources so the KAI Scheduler can schedule pods normally.
###############################################################################
section "Phase 5: Dynamo Platform (v${DYNAMO_VERSION})"

CRDS_TGZ="/tmp/dynamo-crds-${DYNAMO_VERSION}.tgz"
PLATFORM_TGZ="/tmp/dynamo-platform-${DYNAMO_VERSION}.tgz"

if kubectl get crd dynamographdeployments.nvidia.com &>/dev/null; then
  ok "Dynamo CRDs already present — skipping platform install"
else
  if [[ -z "${NGC_API_KEY:-}" ]]; then
    echo ""
    fail "NGC_API_KEY is required. Run:  sudo NGC_API_KEY=<key> bash $0"
  fi

  kubectl create namespace "$DYNAMO_NAMESPACE" 2>/dev/null || true

  kubectl create secret docker-registry nvcr-imagepullsecret \
    --docker-server=nvcr.io \
    --docker-username='$oauthtoken' \
    --docker-password="$NGC_API_KEY" \
    --namespace "$DYNAMO_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  ok "NGC image-pull secret created in $DYNAMO_NAMESPACE"

  # Install Dynamo CRDs
  info "Downloading dynamo-crds chart (v${DYNAMO_VERSION})..."
  curl -fSL "${NGC_HELM_BASE}/dynamo-crds-${DYNAMO_VERSION}.tgz" -o "$CRDS_TGZ"

  info "Installing Dynamo CRDs..."
  helm upgrade --install dynamo-crds "$CRDS_TGZ" --namespace default --wait
  ok "Dynamo CRDs installed"

  # Download platform chart and pre-install Grove/KAI CRDs
  info "Downloading dynamo-platform chart (v${DYNAMO_VERSION})..."
  curl -fSL "${NGC_HELM_BASE}/dynamo-platform-${DYNAMO_VERSION}.tgz" -o "$PLATFORM_TGZ"

  info "Pre-installing KAI Scheduler and Grove CRDs..."
  EXTRACT_DIR="/tmp/dynamo-platform-extract"
  rm -rf "$EXTRACT_DIR" && mkdir -p "$EXTRACT_DIR"
  tar xzf "$PLATFORM_TGZ" -C "$EXTRACT_DIR"

  KAI_CRDS="$EXTRACT_DIR/dynamo-platform/charts/kai-scheduler/crds"
  [[ -d "$KAI_CRDS" ]] && kubectl apply -f "$KAI_CRDS/" && ok "KAI Scheduler CRDs applied"

  GROVE_CRDS="$EXTRACT_DIR/dynamo-platform/charts/grove-charts/crds"
  [[ -d "$GROVE_CRDS" ]] && kubectl apply --server-side -f "$GROVE_CRDS/" && ok "Grove CRDs applied"
  rm -rf "$EXTRACT_DIR"

  # Fix: kube-rbac-proxy image moved from gcr.io to registry.k8s.io
  info "Pre-pulling kube-rbac-proxy image..."
  ctr -n k8s.io images pull registry.k8s.io/kubebuilder/kube-rbac-proxy:v0.15.0 2>/dev/null || true
  ctr -n k8s.io images tag registry.k8s.io/kubebuilder/kube-rbac-proxy:v0.15.0 \
    gcr.io/kubebuilder/kube-rbac-proxy:v0.15.0 2>/dev/null || true

  # ClusterPolicy CRD stub — KAI operator watches this (normally from GPU Operator)
  kubectl apply -f - <<CPEOF
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: clusterpolicies.nvidia.com
spec:
  group: nvidia.com
  names:
    kind: ClusterPolicy
    listKind: ClusterPolicyList
    plural: clusterpolicies
    singular: clusterpolicy
  scope: Cluster
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
CPEOF

  info "Installing Dynamo platform (operator, etcd, NATS, Grove, KAI Scheduler)..."
  helm upgrade --install dynamo-platform "$PLATFORM_TGZ" \
    --namespace "$DYNAMO_NAMESPACE" \
    --set "dynamo-operator.webhook.enabled=false" \
    --set "grove.enabled=true" \
    --set "kai-scheduler.enabled=true" \
    --wait --timeout 300s

  rm -f "$CRDS_TGZ" "$PLATFORM_TGZ"

  wait_for "Dynamo CRDs registered" "kubectl get crd dynamographdeployments.nvidia.com"

  # KAI Scheduler prerequisites for CPU-only nodes
  info "Configuring KAI Scheduler for CPU-only node..."

  # Create the scheduling queue
  kubectl apply -f - <<QEOF
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata:
  name: dynamo
spec:
  displayName: dynamo
  resources:
    gpu:
      quota: -1
    cpu:
      quota: -1
    memory:
      quota: -1
QEOF

  # Label node for KAI scheduler nodepool
  NODE_NAME="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
  kubectl label node "$NODE_NAME" kai.scheduler/nodepool=default --overwrite

  # Advertise fake GPU resources so KAI can schedule pods
  info "Advertising simulated GPU resources on node..."
  kubectl proxy --port=8099 &
  PROXY_PID=$!
  sleep 2
  curl -s -X PATCH "http://localhost:8099/api/v1/nodes/$NODE_NAME/status" \
    -H "Content-Type: application/strategic-merge-patch+json" \
    -d '{"status":{"capacity":{"nvidia.com/gpu":"4"},"allocatable":{"nvidia.com/gpu":"4"}}}' \
    > /dev/null
  kill $PROXY_PID 2>/dev/null || true
  ok "Node advertises 4 simulated GPUs for KAI Scheduler"

  # Wait for KAI operator to fully initialize (creates podgroup-controller, etc.)
  wait_for "KAI operator running" \
    "kubectl get pods -n $DYNAMO_NAMESPACE -l app=kai-operator -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running" 60 5
  wait_for "Podgroup controller running" \
    "kubectl get pods -n $DYNAMO_NAMESPACE --no-headers 2>/dev/null | grep -q 'podgroup-controller.*Running'" 90 5

  info "Verifying Dynamo platform pods..."
  wait_for "Dynamo operator running" \
    "kubectl get pods -n $DYNAMO_NAMESPACE -o jsonpath='{.items[?(@.metadata.labels.app\\.kubernetes\\.io/name==\"dynamo-operator\")].status.phase}' | grep -q Running" 60 5
  wait_for "etcd running" \
    "kubectl get pods -n $DYNAMO_NAMESPACE -l app.kubernetes.io/name=etcd -o jsonpath='{.items[0].status.phase}' | grep -q Running" 60 5
  wait_for "NATS running" \
    "kubectl get pods -n $DYNAMO_NAMESPACE -l app.kubernetes.io/name=nats -o jsonpath='{.items[0].status.phase}' | grep -q Running" 60 5

  ok "Dynamo platform installed (operator + etcd + NATS)"
fi

###############################################################################
# Phase 6 — In-cluster Docker registry
###############################################################################
section "Phase 6: In-Cluster Docker Registry"

NODE_NAME="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"

if kubectl get deploy/registry -n kube-system &>/dev/null; then
  ok "Registry deployment already exists — skipping creation"
else
  info "Deploying in-cluster registry..."
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

wait_for "Registry pod ready" "kubectl rollout status deploy/registry -n kube-system --timeout=5s"

REGISTRY_IP="$(kubectl get svc registry -n kube-system -o jsonpath='{.spec.clusterIP}')"
info "Registry ClusterIP: $REGISTRY_IP:5000"

# Configure containerd to trust the in-cluster registry (HTTP, no TLS)
info "Configuring containerd to trust $REGISTRY_IP:5000..."
mkdir -p "/etc/containerd/certs.d/${REGISTRY_IP}:5000"
cat > "/etc/containerd/certs.d/${REGISTRY_IP}:5000/hosts.toml" <<EOF
server = "http://${REGISTRY_IP}:5000"
[host."http://${REGISTRY_IP}:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF

# Configure Docker daemon to trust the insecure registry (for docker push)
mkdir -p /etc/docker
DOCKER_CONF="/etc/docker/daemon.json"
if [[ -f "$DOCKER_CONF" ]]; then
  # Merge insecure-registries into existing config
  jq --arg reg "$REGISTRY_IP:5000" \
    '.["insecure-registries"] = (.["insecure-registries"] // [] | . + [$reg] | unique)' \
    "$DOCKER_CONF" > /tmp/daemon.json && mv /tmp/daemon.json "$DOCKER_CONF"
else
  echo "{\"insecure-registries\": [\"$REGISTRY_IP:5000\"]}" > "$DOCKER_CONF"
fi
systemctl restart docker 2>/dev/null || true

systemctl restart containerd
wait_for "Node Ready after containerd restart" "kubectl get nodes | grep -qw Ready" 30 5
ok "In-cluster registry is up at $REGISTRY_IP:5000"

###############################################################################
# Phase 7 — Copy lab files & build mocker image
###############################################################################
section "Phase 7: Lab Files & Mocker Image"

info "Copying lab files to $LAB_DIR..."
mkdir -p "$LAB_DIR"
cp -r "$SCRIPT_DIR"/. "$LAB_DIR"/
chmod +x "$LAB_DIR/load-gen.py" 2>/dev/null || true

if [[ -n "${SUDO_USER:-}" ]]; then
  chown -R "$(id -u "$SUDO_USER"):$(id -g "$SUDO_USER")" "$LAB_DIR"
fi
ok "Lab files at $LAB_DIR"

info "Building dynamo-mocker:1.0.0..."
docker build -t "${REGISTRY_IP}:5000/dynamo-mocker:1.0.0" "$LAB_DIR/build/"

info "Pushing to in-cluster registry..."
docker push "${REGISTRY_IP}:5000/dynamo-mocker:1.0.0"

wait_for "Image in registry" \
  "curl -sf http://${REGISTRY_IP}:5000/v2/_catalog | grep -q dynamo-mocker"
ok "dynamo-mocker:1.0.0 pushed to registry"

###############################################################################
# Phase 8 — Update deployment manifest
###############################################################################
section "Phase 8: Deployment Manifest"

MANIFEST="$LAB_DIR/dynamo-lab-deployment.yaml"
info "Patching image references and pull policy..."
sed -i "s|10\.100\.11\.173:5000|${REGISTRY_IP}:5000|g" "$MANIFEST"
sed -i "s|imagePullPolicy: Never|imagePullPolicy: IfNotPresent|g" "$MANIFEST"

IMAGE_COUNT="$(grep -c "${REGISTRY_IP}:5000/dynamo-mocker:1.0.0" "$MANIFEST")"
if [[ "$IMAGE_COUNT" -eq 4 ]]; then
  ok "All 4 image references updated"
else
  warn "Expected 4 image references, found $IMAGE_COUNT — verify $MANIFEST manually"
fi

###############################################################################
# Phase 9 — Prometheus (on port 9090 to match Planner defaults)
###############################################################################
section "Phase 9: Prometheus"

if kubectl get deploy -n monitoring prometheus-kube-prometheus-prometheus &>/dev/null; then
  ok "Prometheus already deployed — skipping"
else
  info "Adding Prometheus Helm repo..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update

  kubectl create namespace monitoring 2>/dev/null || true

  cat > /tmp/prometheus-values-$$.yaml <<'PROMEOF'
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
  global:
    scrape_interval: 15s
  service:
    type: ClusterIP
    servicePort: 9090
  extraScrapeConfigs: |
    - job_name: dynamo-frontend
      scrape_interval: 15s
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
      - source_labels: [__meta_kubernetes_pod_label_nvidia_com_dynamo_namespace]
        target_label: dynamo_namespace
PROMEOF

  helm install prometheus prometheus-community/prometheus \
    -n monitoring -f /tmp/prometheus-values-$$.yaml --wait --timeout 300s
  rm -f /tmp/prometheus-values-$$.yaml

  # The chart's extraScrapeConfigs value doesn't always render into the ConfigMap.
  # Patch it directly to guarantee the dynamo-frontend job is present.
  info "Patching Prometheus ConfigMap with dynamo-frontend scrape job..."
  kubectl get cm prometheus-kube-prometheus-prometheus -n monitoring -o yaml > /tmp/prom-cm-$$.yaml
  if ! grep -q "dynamo-frontend" /tmp/prom-cm-$$.yaml; then
    sed -i '/scrape_configs:/a\
    - job_name: dynamo-frontend\
      scrape_interval: 15s\
      kubernetes_sd_configs:\
      - role: pod\
        namespaces:\
          names: [dynamo-lab]\
      relabel_configs:\
      - source_labels: [__meta_kubernetes_pod_label_nvidia_com_dynamo_component_type]\
        action: keep\
        regex: frontend\
      - source_labels: [__meta_kubernetes_pod_ip]\
        target_label: __address__\
        replacement: ${1}:8000\
      - source_labels: [__meta_kubernetes_pod_name]\
        target_label: pod\
      - source_labels: [__meta_kubernetes_namespace]\
        target_label: namespace\
      - source_labels: [__meta_kubernetes_pod_label_nvidia_com_dynamo_namespace]\
        target_label: dynamo_namespace' /tmp/prom-cm-$$.yaml
    kubectl apply -f /tmp/prom-cm-$$.yaml
    kubectl rollout restart deploy/prometheus-kube-prometheus-prometheus -n monitoring
  fi
  rm -f /tmp/prom-cm-$$.yaml
  ok "Prometheus installed"
fi

wait_for "Prometheus server ready" \
  "kubectl rollout status deploy/prometheus-kube-prometheus-prometheus -n monitoring --timeout=5s"

###############################################################################
# Phase 10 — Deploy lab workload
###############################################################################
section "Phase 10: Deploy Lab Workload"

kubectl create namespace dynamo-lab 2>/dev/null || true

# Create RBAC for worker metadata (operator doesn't grant this automatically)
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dynamo-worker-metadata
  namespace: dynamo-lab
rules:
- apiGroups: ["nvidia.com"]
  resources: ["dynamoworkermetadatas"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["nvidia.com"]
  resources: ["dynamographdeployments", "dynamographdeployments/status",
              "dynamographdeploymentscalingadapters", "dynamographdeploymentscalingadapters/status"]
  verbs: ["get", "list", "watch", "update", "patch"]
EOF

kubectl apply -f "$MANIFEST" -n dynamo-lab

# Wait for the operator to create the service account, then bind RBAC
info "Waiting for operator to create resources..."
wait_for "Service account created" \
  "kubectl get sa dynamo-lab-k8s-service-discovery -n dynamo-lab" 30 3

kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dynamo-worker-metadata
  namespace: dynamo-lab
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: dynamo-worker-metadata
subjects:
- kind: ServiceAccount
  name: dynamo-lab-k8s-service-discovery
  namespace: dynamo-lab
EOF

# With Grove enabled, the operator creates PodCliqueSets → PodCliques → Pods.
# POD_UID is baked into the DGD manifest (extraPodSpec.mainContainer.env).
info "Waiting for Grove resources and pods..."
wait_for "PodCliqueSet created" \
  "kubectl get podcliqueset dynamo-lab -n dynamo-lab" 60 3

wait_for "All 4 pods running" \
  "[ \$(kubectl get pods -n dynamo-lab --no-headers 2>/dev/null | grep -c Running) -ge 4 ]" 120 5

ok "All 4 lab pods are running"

###############################################################################
# Phase 11 — Smoke tests
###############################################################################
section "Phase 11: Smoke Tests"

PASS=0
TOTAL=4

# Test 1 — Frontend responds to inference requests
info "Test 1: Frontend responds to /v1/completions"
FRONTEND_IP="$(kubectl get svc dynamo-lab-frontend -n dynamo-lab -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")"
if [[ -n "$FRONTEND_IP" ]]; then
  RESPONSE="$(curl -sf --max-time 10 "http://${FRONTEND_IP}:8000/v1/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"nvidia/Llama-3.1-8B-Instruct-FP8","prompt":"hello","max_tokens":10,"stream":false}' 2>/dev/null || echo "")"
  if echo "$RESPONSE" | jq -e '.usage' &>/dev/null; then
    ok "Frontend returned valid response"
    PASS=$((PASS + 1))
  else
    warn "Frontend did not return expected response"
  fi
else
  warn "Frontend service not found"
fi

# Test 2 — Grove resources exist
info "Test 2: Grove resources (PodCliqueSet, PodCliques, PodGang)"
PCS_COUNT="$(kubectl get podcliquesets -n dynamo-lab --no-headers 2>/dev/null | wc -l)"
PC_COUNT="$(kubectl get podcliques -n dynamo-lab --no-headers 2>/dev/null | wc -l)"
PG_COUNT="$(kubectl get podgangs -n dynamo-lab --no-headers 2>/dev/null | wc -l)"
if [[ "$PCS_COUNT" -ge 1 && "$PC_COUNT" -ge 4 && "$PG_COUNT" -ge 1 ]]; then
  ok "Grove: ${PCS_COUNT} PodCliqueSet, ${PC_COUNT} PodCliques, ${PG_COUNT} PodGang"
  PASS=$((PASS + 1))
else
  warn "Grove resources incomplete (PCS=$PCS_COUNT, PC=$PC_COUNT, PG=$PG_COUNT)"
fi

# Test 3 — Planner control loop is running
info "Test 3: Planner logs show activity"
PLANNER_LOG="$(kubectl logs -n dynamo-lab -l nvidia.com/dynamo-component-type=planner --tail=20 2>/dev/null || echo "")"
if echo "$PLANNER_LOG" | grep -qi "adjustment\|started\|interval\|planner"; then
  ok "Planner control loop is active"
  PASS=$((PASS + 1))
else
  warn "Planner logs do not show expected activity"
fi

# Test 4 — Prometheus is scraping the frontend
info "Test 4: Prometheus scrapes frontend"
PROM_IP="$(kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")"
PROM_PORT="$(kubectl get svc -n monitoring prometheus-kube-prometheus-prometheus -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "9090")"
if [[ -n "$PROM_IP" ]]; then
  TARGETS="$(curl -sf --max-time 10 "http://${PROM_IP}:${PROM_PORT}/api/v1/query" \
    --data-urlencode 'query=up{job="dynamo-frontend"}' 2>/dev/null || echo "")"
  TARGET_COUNT="$(echo "$TARGETS" | jq -r '.data.result | length' 2>/dev/null || echo 0)"
  if [[ "$TARGET_COUNT" -ge 1 ]]; then
    ok "Prometheus found $TARGET_COUNT scrape target(s)"
    PASS=$((PASS + 1))
  else
    warn "Prometheus has no frontend scrape targets yet (may need a minute to discover)"
  fi
else
  warn "Prometheus service not found"
fi

###############################################################################
# Summary
###############################################################################
section "Setup Complete"

echo ""
echo "  Smoke tests: $PASS/$TOTAL passed"
echo ""
echo "  Lab files:     $LAB_DIR"
echo "  Registry:      $REGISTRY_IP:5000"
echo "  Frontend:      ${FRONTEND_IP:-unknown}:8000"
echo "  Prometheus:    ${PROM_IP:-unknown}:${PROM_PORT:-9090}"
echo ""
echo "  Quick start:"
echo "    kubectl get pods -n dynamo-lab"
echo "    python3 $LAB_DIR/load-gen.py --url http://${FRONTEND_IP:-\$FRONTEND_IP}:8000 --rps 5 --duration 90"
echo ""

if [[ "$PASS" -eq "$TOTAL" ]]; then
  ok "All smoke tests passed — ready for the workshop!"
else
  warn "$((TOTAL - PASS)) smoke test(s) failed — check warnings above"
  warn "Some tests (e.g. Prometheus scrape) may pass after a minute or two"
fi
