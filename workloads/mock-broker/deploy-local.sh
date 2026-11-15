#!/usr/bin/env bash
set -euo pipefail
CLUSTER_NAME="${CLUSTER_NAME:-chaos-lab}"
CONTEXT="$CLUSTER_NAME" # minikube 프로필 이름 = kubectl context
DIR="$(cd "$(dirname "$0")" && pwd)"
TAG="${TAG:-dev}"
# Avoid traversing Windows/WSL virtual environments and cache xattrs.
tar -C "$DIR" --exclude='__pycache__' --exclude='*.pyc' \
  -cf - Dockerfile requirements.txt mock_broker \
  | docker build -t "chaos-lab-mock-broker:$TAG" -
minikube image load "chaos-lab-mock-broker:$TAG" -p "$CLUSTER_NAME"
helm --kube-context "$CONTEXT" upgrade --install mock-broker "$DIR/chart" \
  --namespace exchange --set image.tag="$TAG" "$@" --wait --timeout 180s
kubectl --context "$CONTEXT" -n exchange rollout restart deployment/mock-broker
kubectl --context "$CONTEXT" -n exchange rollout status deployment/mock-broker --timeout=180s
