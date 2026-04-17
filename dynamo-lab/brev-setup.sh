#!/bin/bash
# =============================================================================
# brev-setup.sh — Brev launchable setup script for the Dynamo Grove & Planner lab
#
# This script is uploaded to the Brev launchable wizard (Step 2: "File Upload").
# It runs as the ubuntu user after the VM is provisioned.
#
# What it does:
#   1. Clones the lab repo (contains Dockerfile, exercises, profiling data)
#   2. Runs setup-node.sh with sudo to install K8s + Dynamo + deploy the lab
# =============================================================================
set -euo pipefail

# NGC API key for pulling Dynamo Helm charts from NGC registry.
# Set via environment or hardcode here for workshop provisioning.
# Invalidate after the workshop.
NGC_API_KEY="${NGC_API_KEY:-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}" # disable-trufflehog: temporary workshop key, invalidated post-event
LAB_REPO="https://github.com/jpbueno/dynamo-grove-planner-lab.git"

echo "========================================="
echo "  Dynamo Grove & Planner Lab Setup"
echo "========================================="

# Clone the repo to get lab files (Dockerfile, exercises, profiling data)
cd ~
if [[ -d dynamo-grove-planner-lab ]]; then
  echo "Repo already cloned — pulling latest..."
  cd dynamo-grove-planner-lab && git pull && cd ~
else
  echo "Cloning lab repo..."
  git clone "$LAB_REPO"
fi

# Run the full setup script as root
sudo NGC_API_KEY="$NGC_API_KEY" bash ~/dynamo-grove-planner-lab/dynamo-lab/setup-node.sh

echo ""
echo "========================================="
echo "  Setup complete! Run the exercises:"
echo "    cat ~/dynamo-lab/grove-exercise.md"
echo "    cat ~/dynamo-lab/planner-exercise.md"
echo "========================================="
