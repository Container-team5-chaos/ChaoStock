#!/usr/bin/env bash
# 로컬 minikube 클러스터 삭제. 클러스터가 없어도 성공으로 끝난다 (멱등)
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-chaos-lab}"

if minikube profile list -o json 2>/dev/null | grep -Eq "\"Name\": ?\"$CLUSTER_NAME\""; then
  minikube delete -p "$CLUSTER_NAME"
else
  echo "minikube 클러스터 '$CLUSTER_NAME' 없음 — 삭제할 것이 없습니다"
fi
