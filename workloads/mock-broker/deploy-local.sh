#!/usr/bin/env bash
set -euo pipefail
CLUSTER_NAME="${CLUSTER_NAME:-chaos-lab}"
CONTEXT="kind-${CLUSTER_NAME}"
DIR="$(cd "$(dirname "$0")" && pwd)"
TAG="${TAG:-dev}"
# Avoid traversing Windows/WSL virtual environments and cache xattrs.
tar -C "$DIR" --exclude='__pycache__' --exclude='*.pyc' \
  -cf - Dockerfile requirements.txt mock_broker \
  | docker build -t "chaos-lab-mock-broker:$TAG" -
kind load docker-image "chaos-lab-mock-broker:$TAG" --name "$CLUSTER_NAME"
helm --kube-context "$CONTEXT" upgrade --install mock-broker "$DIR/chart" \
  --namespace exchange --set image.tag="$TAG" "$@" --wait --timeout 180s
kubectl --context "$CONTEXT" -n exchange rollout restart deployment/mock-broker
kubectl --context "$CONTEXT" -n exchange rollout status deployment/mock-broker --timeout=180s
