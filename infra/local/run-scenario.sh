#!/usr/bin/env bash
# 시나리오 하나를 실행기 Job으로 돌리고, 끝나면 결과를 노트북으로 꺼낸다 (docs/operations.md 4~5번).
#
# 사용법 (Chaos-lab 루트, Git Bash 또는 WSL):
#   bash infra/local/run-scenario.sh pod-kill
#   bash infra/local/run-scenario.sh broker-delay
#   RUN_ID=r-demo1 bash infra/local/run-scenario.sh pod-kill
#   SKIP_PREFLIGHT=1 bash infra/local/run-scenario.sh pod-kill   # 점검 생략 (디버깅용, 판정 증거로 쓰지 않음)
#
# 순서: preflight.sh → 실행기 Job 적용 → 로그 따라가기 → 끝나면 fetch-run.sh
# DB 초기화(reset-db.sh)는 하지 않는다. 이전 run 결과를 꺼냈는지 사람이 확인하고 따로 돌린다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-chaos-lab}"
CTX="$CLUSTER_NAME"
NS="${NS:-exchange}"
TIMEOUT="${TIMEOUT:-60m}"

kn() { kubectl --context "$CTX" -n "$NS" "$@"; }

arg="${1:-}"
[ -n "$arg" ] || { echo "사용법: $0 <시나리오 이름>" >&2; exit 2; }
SCENARIO="$(basename "${arg%.yaml}")"
[ -f "$ROOT/experiments/scenarios/$SCENARIO.yaml" ] || {
  echo "시나리오 파일이 없습니다: experiments/scenarios/$SCENARIO.yaml" >&2
  exit 2
}
RUN_ID="${RUN_ID:-r-$(date +%m%d%H%M%S)}"
printf '%s' "$RUN_ID" | grep -Eq '^[a-z0-9-]{3,40}$' || { echo "RUN_ID 형식 오류: $RUN_ID" >&2; exit 2; }

# 1. 점검 (FAIL이면 시작하지 않는다)
if [ "${SKIP_PREFLIGHT:-0}" != "1" ]; then
  bash "$ROOT/infra/local/preflight.sh" "$SCENARIO" || {
    echo "preflight FAIL — 시작하지 않습니다." >&2
    exit 1
  }
else
  echo "SKIP_PREFLIGHT=1 — 점검 없이 시작합니다 (이 run은 판정 증거로 쓰지 마세요)"
fi

# 2. 실행기 권한·저장소 (이미 있으면 그대로)
kubectl --context "$CTX" apply -f "$ROOT/orchestrator/k8s/rbac.yaml" -f "$ROOT/orchestrator/k8s/pvc.yaml" >/dev/null

# 3. Job 적용
echo "run_id=$RUN_ID  scenario=$SCENARIO"
tr -d '\r' <"$ROOT/orchestrator/k8s/job.yaml" \
  | sed -e "s/__RUN_ID__/$RUN_ID/g" -e "s/__SCENARIO__/$SCENARIO/g" \
  | kubectl --context "$CTX" apply -f -

# 4. 로그 따라가기 → 끝날 때까지 대기
echo "로그 (Ctrl+C로 로그만 끊어도 실험은 계속됩니다)"
kn wait --for=condition=Ready pod -l "chaos/run-id=$RUN_ID,app.kubernetes.io/name=chaos-orchestrator" --timeout=180s >/dev/null 2>&1 || true
kn logs -f "job/chaos-run-$RUN_ID" || true
if ! kn wait --for=condition=complete "job/chaos-run-$RUN_ID" --timeout="$TIMEOUT" >/dev/null 2>&1; then
  echo "실행기 Job이 complete가 아닙니다 (실행기가 죽었거나 시간 초과)." >&2
  kn get pods -l "chaos/run-id=$RUN_ID" >&2 || true
  echo "상태 확인: kubectl --context $CTX -n $NS describe job/chaos-run-$RUN_ID" >&2
fi

# 5. 결과 꺼내기
bash "$ROOT/infra/local/fetch-run.sh" "$RUN_ID"
echo
echo "판정 요약: runs/$RUN_ID/report.md"
echo "다음 run 전에: bash infra/local/reset-db.sh -y --force   (결과를 꺼낸 뒤)"
