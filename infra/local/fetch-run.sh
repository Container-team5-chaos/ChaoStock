#!/usr/bin/env bash
# 실행기 PVC에서 run 결과를 노트북으로 꺼낸다 (docs/operations.md 5번).
#
# 사용법 (Chaos-lab 루트, Git Bash 또는 WSL):
#   bash infra/local/fetch-run.sh r-1121093000        # → runs/r-1121093000/
#   bash infra/local/fetch-run.sh --list              # PVC에 있는 run 목록
#
# PVC(chaos-orchestrator-state)는 ReadWriteOnce라 실행기 Job이 끝난 뒤에만 붙일 수 있다.
# 잠깐 띄운 busybox Pod로 /var/lib/orchestrator/runs/<run_id>/와 state.json을 복사하고 지운다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-chaos-lab}"
CTX="$CLUSTER_NAME"
NS="${NS:-exchange}"
PVC="chaos-orchestrator-state"
MOUNT="/var/lib/orchestrator"
HELPER_IMAGE="${HELPER_IMAGE:-busybox:1.36}"

kn() { kubectl --context "$CTX" -n "$NS" "$@"; }

arg="${1:-}"
[ -n "$arg" ] || { echo "사용법: $0 <run_id> | --list" >&2; exit 2; }
if [ "$arg" != "--list" ] && ! printf '%s' "$arg" | grep -Eq '^[a-z0-9-]{3,40}$'; then
  echo "run_id 형식이 아닙니다: $arg (^[a-z0-9-]{3,40}$)" >&2
  exit 2
fi

# 실행 중인 실행기 Job이 PVC를 쓰고 있으면 기다려야 한다
active="$(kn get jobs -l app.kubernetes.io/name=chaos-orchestrator \
  -o jsonpath='{range .items[?(@.status.active)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c . || true)"
if [ "$active" != "0" ]; then
  echo "실행 중인 실행기 Job이 있어 PVC를 붙일 수 없습니다. 끝난 뒤 다시 실행하세요." >&2
  exit 1
fi

pod="fetch-run-$(date +%s)"
cleanup() { kn delete pod "$pod" --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

kn apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  labels: {app.kubernetes.io/name: fetch-run}
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: $HELPER_IMAGE
      command: ["sleep", "600"]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {cpu: 100m, memory: 64Mi}
      volumeMounts: [{name: state, mountPath: $MOUNT, readOnly: true}]
  volumes:
    - name: state
      persistentVolumeClaim: {claimName: $PVC, readOnly: true}
YAML
kn wait --for=condition=Ready "pod/$pod" --timeout=120s >/dev/null

if [ "$arg" = "--list" ]; then
  MSYS_NO_PATHCONV=1 kn exec "$pod" -- ls -1t "$MOUNT/runs" 2>/dev/null || echo "(run 없음)"
  exit 0
fi

run_id="$arg"
if ! MSYS_NO_PATHCONV=1 kn exec "$pod" -- test -d "$MOUNT/runs/$run_id"; then
  echo "PVC에 runs/$run_id가 없습니다. 목록: $0 --list" >&2
  exit 1
fi

dest="$ROOT/runs/$run_id"
mkdir -p "$dest"
# kubectl cp는 Git Bash 경로 변환에 걸리므로 tar로 받는다
MSYS_NO_PATHCONV=1 kn exec "$pod" -- tar -C "$MOUNT/runs" -cf - "$run_id" | tar -C "$ROOT/runs" -xf -
MSYS_NO_PATHCONV=1 kn exec "$pod" -- cat "$MOUNT/state.json" >"$dest/state.json" 2>/dev/null || true

echo "→ runs/$run_id/"
ls -1 "$dest"
if [ -f "$dest/state.json" ] && grep -q "\"run_id\": \"$run_id\"" "$dest/state.json"; then
  sed -nE 's/.*"(result|phase|cleanup|reason)": "([^"]*)".*/  \1=\2/p' "$dest/state.json"
else
  echo "  (state.json은 다른 run 기록이라 참고용입니다)"
fi
