#!/usr/bin/env bash
# 정산 순서(settle_seq) 확인 — w4 2번 B·C·D 통합 확인용
# adapter 모드에서는 접수 순서(orders.id)와 정산 순서(orders.settle_seq)가 다를 수 있다.
# 같은 계좌에서 나중에 접수된 주문이 먼저 정산된 "역전"이 있는지, 그중 매도가 끼어 평단가가 달라지는 경우가 있는지 본다.
# 판정기(judge)는 settle_seq 순서로 평단가를 다시 계산하므로(#45), 역전이 있어도 report.md의 invariants(avg)가 PASS면 정상이다.
#
# 사용법 (Chaos-lab 루트, run이 끝난 뒤 DB 초기화 전에):
#   bash infra/local/settle-order-check.sh                   # DB 전체
#   RUN_ID=r-1120213000 bash infra/local/settle-order-check.sh   # 한 run의 주문만 (client_order_id가 k6-<run_id>로 시작)
# 결과: 화면 + ~/chaos-test/settle-order-<RUN_ID 또는 all>-<시각>.txt
set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-chaos-lab}"
CTX="$CLUSTER_NAME" # minikube 프로필 이름 = kubectl context
NS="${NS:-exchange}"
RUN_ID="${RUN_ID:-}"
SAMPLES="${SAMPLES:-10}"

if [ -n "$RUN_ID" ]; then
  [[ "$RUN_ID" =~ ^[a-z0-9-]{3,40}$ ]] || { echo "RUN_ID 형식이 아닙니다: $RUN_ID" >&2; exit 2; }
  WHERE="client_order_id LIKE 'k6-${RUN_ID}%'"
else
  WHERE="TRUE"
fi
OUT="$HOME/chaos-test/settle-order-${RUN_ID:-all}-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$(dirname "$OUT")"

sql() { kubectl --context "$CTX" -n "$NS" exec -i statefulset/postgres -- psql -U exchange -d exchange -P pager=off "$@"; }

{
echo "정산 순서 확인  범위=${RUN_ID:-DB 전체}  context=$CTX  time=$(date '+%Y-%m-%d %H:%M:%S %z')"
echo
echo "== 1. 정산 번호 기록 상태"
echo "   기대: filled_no_seq 0 (체결 주문은 모두 번호가 있음), seq_on_unfilled 0, dup_seq 0"
sql <<SQL
SELECT count(*)                                                    AS orders,
       count(*) FILTER (WHERE status = 'filled')                   AS filled,
       count(*) FILTER (WHERE status = 'pending')                  AS pending,
       count(*) FILTER (WHERE status = 'rejected')                 AS rejected,
       count(*) FILTER (WHERE status = 'filled' AND settle_seq IS NULL)     AS filled_no_seq,
       count(*) FILTER (WHERE status <> 'filled' AND settle_seq IS NOT NULL) AS seq_on_unfilled,
       count(settle_seq) - count(DISTINCT settle_seq)              AS dup_seq
FROM orders
WHERE $WHERE;
SQL

echo "== 2. 정산 순서 역전 (같은 계좌·마켓에서 나중에 접수된 주문이 먼저 정산됨)"
echo "   inversions > 0 이면 역전 사례가 있다. inversions_with_ask > 0 이면 주문 번호 순 재계산과 평단가가 달라지는 경우다"
sql <<SQL
WITH s AS (
  SELECT id, user_id, market, side, settle_seq,
         lag(id)   OVER w AS prev_id,
         lag(side) OVER w AS prev_side
  FROM orders
  WHERE status = 'filled' AND settle_seq IS NOT NULL AND $WHERE
  WINDOW w AS (PARTITION BY user_id, market ORDER BY settle_seq)
)
SELECT count(*)                                              AS inversions,
       count(*) FILTER (WHERE side = 'ask' OR prev_side = 'ask') AS inversions_with_ask,
       count(DISTINCT user_id)                               AS users
FROM s
WHERE prev_id > id;
SQL

echo "== 3. 역전 사례 (최대 ${SAMPLES}건): 정산 순서상 앞 주문(prev)이 접수는 더 늦다"
sql <<SQL
WITH s AS (
  SELECT id, user_id, side, volume, fill_price, settle_seq, created_at, filled_at,
         lag(id)         OVER w AS prev_id,
         lag(side)       OVER w AS prev_side,
         lag(settle_seq) OVER w AS prev_seq,
         lag(created_at) OVER w AS prev_created
  FROM orders
  WHERE status = 'filled' AND settle_seq IS NOT NULL AND $WHERE
  WINDOW w AS (PARTITION BY user_id, market ORDER BY settle_seq)
)
SELECT user_id,
       prev_id  AS "먼저 정산(id)", prev_side AS side1, prev_seq AS seq1,
       id       AS "나중 정산(id)", side      AS side2, settle_seq AS seq2,
       round(extract(epoch FROM (prev_created - created_at))::numeric, 1) AS "먼저 접수한 시간차(초)"
FROM s
WHERE prev_id > id
ORDER BY (side = 'ask' OR prev_side = 'ask') DESC, user_id, settle_seq
LIMIT $SAMPLES;
SQL

echo "== 4. 역전이 있는 계좌의 현재 평단가 (judge가 settle_seq 순서로 재계산한 값과 비교되는 값)"
sql <<SQL
WITH s AS (
  SELECT user_id, market, id, side, lag(id) OVER w AS prev_id, lag(side) OVER w AS prev_side
  FROM orders
  WHERE status = 'filled' AND settle_seq IS NOT NULL AND $WHERE
  WINDOW w AS (PARTITION BY user_id, market ORDER BY settle_seq)
), u AS (
  SELECT DISTINCT user_id, market FROM s
  WHERE prev_id > id AND (side = 'ask' OR prev_side = 'ask')
)
SELECT p.user_id, p.market, p.volume, p.avg_price
FROM positions p JOIN u USING (user_id, market)
ORDER BY p.user_id
LIMIT $SAMPLES;
SQL
} 2>&1 | tr -d '\r' | tee "$OUT"

echo
echo "저장: $OUT"
echo "다음: 같은 run의 report.md에서 기준 'invariants'(avg 포함)가 PASS인지 확인 → 역전이 있는데도 PASS면 2번 통합 확인 완료"
