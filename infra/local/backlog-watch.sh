#!/usr/bin/env bash
# #4(adapter 부하) 확인용: 실험 중 주문 상태별 건수를 주기적으로 기록한다.
# broker-baseline 실행과 동시에 다른 터미널에서 띄우고, 실험이 끝나면 Ctrl+C
#
# 사용법: bash infra/local/backlog-watch.sh            (10초 간격)
#   INTERVAL=5 NS=exchange bash infra/local/backlog-watch.sh
# 결과: ~/chaos-test/backlog-<시각>.csv  (time,elapsed_s,pending,filled,rejected,unknown,filled_per_s)
set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-chaos-lab}"
CONTEXT="$CLUSTER_NAME" # minikube 프로필 이름 = kubectl context
NS="${NS:-exchange}"
INTERVAL="${INTERVAL:-10}"
OUT="$HOME/chaos-test/backlog-$(date +%Y%m%d-%H%M%S).csv"
mkdir -p "$(dirname "$OUT")"

count() { # 상태별 건수 "pending filled rejected unknown"
  kubectl --context "$CONTEXT" -n "$NS" exec statefulset/postgres -- psql -U exchange -d exchange -tA -F' ' -c \
    "SELECT count(*) FILTER (WHERE status='pending'),
            count(*) FILTER (WHERE status='filled'),
            count(*) FILTER (WHERE status='rejected'),
            count(*) FILTER (WHERE status='unknown')
       FROM orders" 2>/dev/null | tr -d '\r'
}

echo "time,elapsed_s,pending,filled,rejected,unknown,filled_per_s" | tee "$OUT"
start=$(date +%s); prev_filled=""
while true; do
  read -r pending filled rejected unknown <<<"$(count)"
  now=$(date +%s)
  rate=""
  if [ -n "${filled:-}" ] && [ -n "$prev_filled" ]; then
    rate=$(awk -v a="$filled" -v b="$prev_filled" -v t="$INTERVAL" 'BEGIN{printf "%.2f", (a-b)/t}')
  fi
  echo "$(date +%H:%M:%S),$((now - start)),${pending:-},${filled:-},${rejected:-},${unknown:-},$rate" | tee -a "$OUT"
  prev_filled="${filled:-}"
  sleep "$INTERVAL"
done
