#!/usr/bin/env bash
# 끊긴 실험을 손으로 정리한다: `orchestrator recover`를 실행기 이미지·PVC로 한 번 돌린다 (docs/operations.md).
# 주입은 하지 않는다. k6에 멈춤 신호를 보내고 Chaos 리소스를 지운 뒤 state.json을 ABORTED로 남긴다.
#
# 사용법 (Chaos-lab 루트, Git Bash 또는 WSL):
#   bash infra/local/recover.sh
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-chaos-lab}"
CTX="$CLUSTER_NAME"
NS="${NS:-exchange}"
RUNNER_IMAGE="${RUNNER_IMAGE:-chaos-orchestrator:dev}"

kn() { kubectl --context "$CTX" -n "$NS" "$@"; }

active="$(kn get jobs -l app.kubernetes.io/name=chaos-orchestrator \
  -o jsonpath='{range .items[?(@.status.active)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
if [ -n "$active" ]; then
  echo "실행 중인 실행기 Job이 있습니다: $active" >&2
  echo "그 Job이 스스로 정리하게 두세요. 정말 멈춰야 하면 Job을 지운 뒤 다시 실행하세요." >&2
  exit 1
fi

pod="orchestrator-recover-$(date +%s)"
trap 'kn delete pod "$pod" --wait=false >/dev/null 2>&1 || true' EXIT
kn apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  labels: {app.kubernetes.io/name: orchestrator-recover}
spec:
  serviceAccountName: chaos-orchestrator
  restartPolicy: Never
  containers:
    - name: orchestrator
      image: $RUNNER_IMAGE
      imagePullPolicy: IfNotPresent
      args: ["--namespace=$NS", "recover"]
      resources:
        requests: {cpu: 50m, memory: 128Mi}
        limits: {cpu: 500m, memory: 256Mi}
      volumeMounts: [{name: state, mountPath: /var/lib/orchestrator}]
  volumes:
    - name: state
      persistentVolumeClaim: {claimName: chaos-orchestrator-state}
YAML
for _ in $(seq 1 120); do
  phase="$(kn get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ] && break
  sleep 1
done
kn logs "$pod" || true
[ "${phase:-}" = "Succeeded" ] || { echo "recover 실패 (phase=${phase:-?})" >&2; exit 1; }
