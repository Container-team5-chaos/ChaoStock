#!/usr/bin/env bash
# 실험 시작 전 점검 (w4 6번): 이전 run이 다음 run의 결과를 오염시키지 않는지 확인한다.
#   - 클러스터·실험 도구가 준비됐는지 (API 서버, Prometheus, Chaos Mesh, 실행기 PVC)
#   - 진행 중이거나 남은 실험이 없는지 (Chaos 리소스, k6·실행기 Job)
#   - 시나리오의 order_mode와 클러스터의 주문 모드가 같은지 (baseline / adapter)
#   - DB가 초기 상태인지 (주문 0건, 계좌 1,000개 × 1,000만 원, adapter 대기열 비어 있음)
#   - 시세가 신선한지, 노드 시계가 맞는지 (stale_price 거절 원인)
#   - 실행기 이미지(minikube 안) 시나리오가 작업 폴더 파일과 같은지
#
# 사용법 (Chaos-lab 루트, Git Bash 또는 WSL):
#   bash infra/local/preflight.sh pod-kill
#   bash infra/local/preflight.sh experiments/scenarios/broker-delay.yaml
#   SKIP_IMAGE=1 bash infra/local/preflight.sh pod-kill   # 실행기 이미지 비교 생략 (약 10초 절약)
# 결과: 화면 + ~/chaos-test/preflight-<시나리오>-<시각>.txt
# 종료 코드: FAIL이 하나라도 있으면 1, 아니면 0 (WARN은 통과)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-chaos-lab}"
CTX="$CLUSTER_NAME" # minikube 프로필 이름 = kubectl context
NS="${NS:-exchange}"
MARKET="${MARKET:-KRW-BTC}"
STALE_MS="${STALE_MS:-5000}"        # 주문 서비스 STALE_MS 기본값
INITIAL_KRW="${INITIAL_KRW:-10000000}" # workloads/order/db/seed.sql
ACCOUNTS="${ACCOUNTS:-1000}"
RUNNER_IMAGE="${RUNNER_IMAGE:-chaos-orchestrator:dev}"

# ---------------------------------------------------------------- 시나리오
arg="${1:-}"
[ -n "$arg" ] || { echo "사용법: $0 <시나리오 이름 또는 파일>" >&2; exit 2; }
if [ -f "$arg" ]; then SCENARIO_FILE="$arg"; else SCENARIO_FILE="$ROOT/experiments/scenarios/${arg%.yaml}.yaml"; fi
[ -f "$SCENARIO_FILE" ] || { echo "시나리오 파일이 없습니다: $SCENARIO_FILE" >&2; exit 2; }
SCENARIO="$(basename "$SCENARIO_FILE" .yaml)"
WANT_MODE="$(tr -d '\r' <"$SCENARIO_FILE" | sed -nE 's/^order_mode:[[:space:]]*([a-z]+).*/\1/p' | head -1)"
HAS_FAULTS=1
tr -d '\r' <"$SCENARIO_FILE" | grep -qE '^faults:[[:space:]]*\[\][[:space:]]*$' && HAS_FAULTS=0

OUT="$HOME/chaos-test/preflight-$SCENARIO-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$(dirname "$OUT")"

k() { kubectl --context "$CTX" "$@"; }
kn() { kubectl --context "$CTX" -n "$NS" "$@"; }
psql_q() { kn exec statefulset/postgres -- psql -U exchange -d exchange -tA -F' ' -c "$1" 2>/dev/null | tr -d '\r'; }
redis_cli() { kn exec deploy/redis -- redis-cli "$@" 2>/dev/null | tr -d '\r'; }

pass=0; warn=0; fail=0
ok()   { echo "PASS  $*" | tee -a "$OUT"; pass=$((pass + 1)); }
wa()   { echo "WARN  $*" | tee -a "$OUT"; warn=$((warn + 1)); }
bad()  { echo "FAIL  $*" | tee -a "$OUT"; fail=$((fail + 1)); }
hint() { echo "      → $*" | tee -a "$OUT"; }
step() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; echo "-- $*" >>"$OUT"; }

{
  echo "preflight  scenario=$SCENARIO  order_mode=${WANT_MODE:-없음}  context=$CTX  namespace=$NS"
  echo "file=$SCENARIO_FILE  git=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)$(git -C "$ROOT" diff HEAD --quiet -- "$SCENARIO_FILE" 2>/dev/null || echo ' (시나리오 파일 수정됨, 커밋 전)')"
  echo "time=$(date '+%Y-%m-%d %H:%M:%S %z')"
} | tee "$OUT"

# 1. 클러스터 ----------------------------------------------------------------
step "1. 클러스터와 실험 도구"
if [ "$(MSYS_NO_PATHCONV=1 kubectl --context "$CTX" get --raw /readyz --request-timeout=10s 2>/dev/null)" = "ok" ]; then
  ok "API 서버 응답"
else
  bad "API 서버 응답 없음"
  hint "minikube status -p $CLUSTER_NAME / minikube start -p $CLUSTER_NAME"
  echo; echo "API 서버가 없어 나머지 점검을 건너뜁니다. 결과: $OUT"; exit 1
fi
others="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^chaos-lab-(control-plane|worker)' || true)"
[ -z "$others" ] && ok "예전 kind 클러스터 없음" || { bad "예전 kind 컨테이너가 떠 있음: $(echo $others)"; hint "docker rm -f $(echo $others)  (minikube 자원을 빼앗아 API 서버가 멈춤)"; }

if k -n monitoring get pods -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -q " Running"; then
  ok "Prometheus 실행 중 (실행기 시작 게이트·drain)"
else
  bad "Prometheus 없음 — LITE 환경에서는 실행기가 시작하지 않음"
  hint "ORDER_MODE=${WANT_MODE:-baseline} bash infra/local/up.sh --with-apps  (LITE 없이)"
fi
if [ "$HAS_FAULTS" = "1" ]; then
  if k -n chaos-mesh get deploy chaos-controller-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -qE '^[1-9]'; then
    ok "Chaos Mesh controller Ready"
  else
    bad "Chaos Mesh controller가 Ready가 아님 (장애 주입 불가)"
  fi
fi
kn get pvc chaos-orchestrator-state >/dev/null 2>&1 && kn get serviceaccount chaos-orchestrator >/dev/null 2>&1 \
  && ok "실행기 PVC·RBAC 있음" \
  || { bad "실행기 PVC 또는 RBAC 없음"; hint "kubectl --context $CTX apply -f orchestrator/k8s/rbac.yaml -f orchestrator/k8s/pvc.yaml"; }

# 2. 남은 실험 ----------------------------------------------------------------
step "2. 진행 중이거나 남은 실험"
chaos="$(k get podchaos,networkchaos -A -l chaos/run-id --no-headers 2>/dev/null)"
[ -z "$chaos" ] && ok "남은 Chaos 리소스 없음" || { bad "Chaos 리소스가 남아 있음 (장애가 계속 걸려 있을 수 있음)"; echo "$chaos" | sed 's/^/      /' | tee -a "$OUT"; hint "실행 중 run이 없으면: kubectl --context $CTX delete podchaos,networkchaos -A -l chaos/run-id"; }

active="$(kn get jobs -o jsonpath='{range .items[?(@.status.active)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E '^(k6-|chaos-run-)' || true)"
[ -z "$active" ] && ok "실행 중인 k6·실행기 Job 없음" || { bad "실행 중인 Job: $(echo $active)"; hint "앞 run이 끝날 때까지 기다리거나 결과를 버릴 거면 delete job"; }

done_jobs="$(kn get jobs -o name 2>/dev/null | grep -cE 'job.batch/(k6-|chaos-run-)' || true)"
if [ "${done_jobs:-0}" = "0" ]; then
  ok "끝난 k6·실행기 Job 없음"
else
  wa "끝난 k6·실행기 Job ${done_jobs}개 (판정 파일은 PVC에 있으니 지워도 됨)"
  hint "kubectl --context $CTX -n $NS get jobs -o name | grep -E 'job.batch/(k6-|chaos-run-)' | xargs -r kubectl --context $CTX -n $NS delete"
fi
# 실행기 Job 재시도(w4 5번): #50 이후에는 실험이 결과를 내면 종료 코드 0(--exit-zero-on-result)이라 재시도하지 않는다.
# 그 옵션이 없고 backoffLimit > 0이면, 결과가 FAIL·INCONCLUSIVE인 run을 Job이 다시 시작해 다음 run과 겹칠 수 있다.
job_yaml="$(tr -d '\r' <"$ROOT/orchestrator/k8s/job.yaml")"
backoff="$(printf '%s\n' "$job_yaml" | sed -nE 's/^[[:space:]]*backoffLimit:[[:space:]]*([0-9]+).*/\1/p')"
if printf '%s\n' "$job_yaml" | grep -q -- '--exit-zero-on-result'; then
  ok "실행기 Job: 결과가 나온 run은 재시도하지 않음 (--exit-zero-on-result, backoffLimit ${backoff:-?}는 실행기가 죽었을 때만)"
elif [ "${backoff:-0}" = "0" ]; then
  ok "실행기 Job backoffLimit 0"
else
  wa "orchestrator/k8s/job.yaml backoffLimit=$backoff, --exit-zero-on-result 없음 — 실패한 run이 다시 시작돼 다음 run과 겹칠 수 있음 (w4 5번, #50)"
  hint "#50 머지 전에는 적용할 때 sed -e 's/backoffLimit: $backoff/backoffLimit: 0/'"
fi

# 3. 주문 모드 ----------------------------------------------------------------
step "3. 주문 모드 (시나리오 order_mode ↔ 클러스터)"
adapter_url="$(kn get deploy order -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ADAPTER_URL")].value}' 2>/dev/null)"
HAVE_MODE=baseline; [ -n "$adapter_url" ] && HAVE_MODE=adapter
if [ -z "$WANT_MODE" ]; then
  bad "시나리오에 order_mode가 없음 (baseline 또는 adapter)"
elif [ "$WANT_MODE" = "$HAVE_MODE" ]; then
  ok "주문 모드 일치: $HAVE_MODE"
else
  bad "주문 모드 불일치: 시나리오 $WANT_MODE ↔ 클러스터 $HAVE_MODE"
  if [ "$WANT_MODE" = "adapter" ]; then
    hint "bash workloads/order/deploy-local.sh -f workloads/order/chart/values-adapter.yaml"
  else
    hint "bash workloads/order/deploy-local.sh"
  fi
fi

ready() { # deployment 이름 → "준비/전체"
  local r; r="$(kn get deploy "$1" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null)"
  [ -n "$r" ] && [ "${r%/*}" = "" ] && r="0$r"
  echo "$r"
}
apps=(order collector)
[ "$HAVE_MODE" = "adapter" ] && apps+=(adapter mock-broker)
for app in "${apps[@]}"; do
  r="$(ready "$app")"
  if [ -n "$r" ] && [ "${r%/*}" = "${r#*/}" ] && [ "${r%/*}" != "0" ]; then
    ok "$app Ready ($r)"
  else
    bad "$app Ready 아님 (${r:-없음})"
  fi
done
kn get statefulset postgres -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '^1$' && ok "postgres Ready" || bad "postgres Ready 아님"

# 4. DB ----------------------------------------------------------------
step "4. DB 초기 상태"
read -r n_orders n_pos <<<"$(psql_q "SELECT (SELECT count(*) FROM orders), (SELECT count(*) FROM positions)")"
if [ "${n_orders:-x}" = "0" ] && [ "${n_pos:-x}" = "0" ]; then
  ok "주문·포지션 0건"
else
  bad "이전 주문·포지션이 남아 있음 (주문 ${n_orders:-?}건, 포지션 ${n_pos:-?}건) — 판정에 섞임"
  hint "bash infra/local/reset-db.sh -y  (출력 마지막 줄 accounts=$ACCOUNTS 확인)"
  if psql_q "SELECT to_regclass('order_external') IS NOT NULL" | grep -q t; then
    pend="$(psql_q "SELECT count(*) FROM orders JOIN order_external USING(client_order_id) WHERE status IN ('pending','unknown')")"
    [ "${pend:-0}" != "0" ] && hint "미정산 외부 주문 ${pend}건 때문에 reset-db.sh가 거부함 → 이전 run 결과를 꺼냈으면 bash infra/local/reset-db.sh -y --force"
  fi
fi
read -r n_acc n_diff <<<"$(psql_q "SELECT count(*), count(*) FILTER (WHERE krw <> $INITIAL_KRW) FROM accounts")"
[ "${n_acc:-x}" = "$ACCOUNTS" ] && [ "${n_diff:-x}" = "0" ] \
  && ok "계좌 $ACCOUNTS개 × $INITIAL_KRW원" \
  || { bad "계좌가 초기 상태가 아님 (계좌 ${n_acc:-?}개, 잔고가 다른 계좌 ${n_diff:-?}개)"; hint "bash infra/local/reset-db.sh -y"; }
[ "$(psql_q "SELECT count(*) FROM information_schema.columns WHERE table_name='orders' AND column_name='settle_seq'")" = "1" ] \
  && ok "orders.settle_seq 열 있음 (#47)" \
  || { wa "orders.settle_seq 열 없음 — 주문 서비스 이미지가 #47 이전 (adapter 판정에서 평단가 재계산 불가)"; hint "bash workloads/order/deploy-local.sh (모드에 맞는 옵션과 함께)로 다시 빌드"; }
if psql_q "SELECT to_regclass('adapter_orders') IS NOT NULL" | grep -q t; then
  ap="$(psql_q "SELECT count(*) FROM adapter_orders WHERE status='pending'")"
  if [ "${ap:-0}" = "0" ]; then
    ok "adapter 대기열 비어 있음"
  elif [ "$WANT_MODE" = "adapter" ]; then
    bad "adapter 대기열에 이전 주문 ${ap}건 — drain의 평소 수준(warmup 최대값)이 부풀어 판정이 틀어짐"
    hint "실행 중 run이 없으면: kubectl --context $CTX -n $NS exec statefulset/postgres -- psql -U exchange -d exchange -c 'TRUNCATE adapter_orders, mock_broker_orders;'"
  else
    wa "adapter 대기열에 이전 주문 ${ap}건 (baseline 시나리오에는 영향 없음)"
  fi
fi

# 5. 시세와 시계 ----------------------------------------------------------------
step "5. 시세 신선도와 노드 시계 (stale_price 거절 원인)"
node_s="$(redis_cli TIME | head -1)"
pc_s="$(date +%s)"
if [ -n "$node_s" ]; then
  skew=$((node_s - pc_s)); abs=${skew#-}
  if [ "$abs" -le 1 ]; then
    ok "노드 시계 차이 ${skew}초 (PC 기준)"
  elif [ "$abs" -lt 3 ]; then
    wa "노드 시계 차이 ${skew}초 (PC 기준)"
  else
    bad "노드 시계 차이 ${skew}초 — 수집기가 업비트 시각과 비교해 시세를 버리거나 주문이 stale_price로 거절될 수 있음"
    hint "PC 절전 후 Docker(WSL) 시계가 밀리는 경우가 많음: wsl --shutdown 후 Docker Desktop 재시작, 또는 minikube stop/start"
  fi
else
  wa "Redis에서 시각을 읽지 못함"
fi
ages=(); stale=0; missing=0
for _ in 1 2 3; do
  read -r s us <<<"$(redis_cli TIME | tr '\n' ' ')"
  cur="$(redis_cli GET "price:$MARKET")"
  ts="$(printf '%s' "$cur" | sed -nE 's/.*"ts": *([0-9]+).*/\1/p')"
  if [ -n "${s:-}" ] && [ -n "${us:-}" ] && [ -n "$ts" ]; then
    age=$((s * 1000 + us / 1000 - ts)); ages+=("${age}ms")
    [ "$age" -gt "$STALE_MS" ] && stale=$((stale + 1))
  else
    missing=$((missing + 1)); ages+=("없음")
  fi
  sleep 2
done
if [ "$missing" = "3" ]; then
  bad "Redis에 price:$MARKET 없음 — 주문이 전부 거절됨"
  hint "kubectl --context $CTX -n $NS logs deploy/collector --tail=50"
elif [ "$stale" = "0" ] && [ "$missing" = "0" ]; then
  ok "시세 신선 (나이 ${ages[*]}, 기준 ${STALE_MS}ms)"
elif [ "$stale" = "3" ]; then
  bad "시세가 계속 ${STALE_MS}ms보다 오래됨 (나이 ${ages[*]}) — 주문이 stale_price(503)로 거절됨"
  hint "수집기 로그와 5번 시계 차이를 확인"
else
  wa "시세가 가끔 오래됨 (나이 ${ages[*]}) — 거래가 뜸한 시간이면 stale_price 거절이 섞일 수 있음"
fi

# 6. 실행기 이미지 ----------------------------------------------------------------
step "6. 실행기 이미지 시나리오 (minikube 안 $RUNNER_IMAGE)"
if [ "${SKIP_IMAGE:-0}" = "1" ]; then
  wa "SKIP_IMAGE=1 — 확인하지 않음"
else
  local_sum="$(tr -d '\r' <"$SCENARIO_FILE" | sha256sum | cut -c1-16)"
  pod="preflight-img-$(date +%s)"
  MSYS_NO_PATHCONV=1 kubectl --context "$CTX" -n "$NS" run "$pod" --image="$RUNNER_IMAGE" --image-pull-policy=Never \
    --restart=Never --labels=app.kubernetes.io/name=preflight --command -- \
    sh -c "tr -d '\r' < /app/experiments/scenarios/$SCENARIO.yaml | sha256sum" >/dev/null 2>&1
  for _ in $(seq 1 30); do
    phase="$(kn get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)"
    [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ] && break
    sleep 1
  done
  image_sum="$(kn logs "$pod" 2>/dev/null | cut -c1-16)"
  kn delete pod "$pod" --wait=false >/dev/null 2>&1
  if [ -z "$image_sum" ]; then
    bad "실행기 이미지에서 시나리오를 읽지 못함 (이미지가 minikube에 없거나 시나리오가 이미지에 없음)"
    hint "docker build -f orchestrator/Dockerfile -t $RUNNER_IMAGE . && minikube image load $RUNNER_IMAGE -p $CLUSTER_NAME"
  elif [ "$image_sum" = "$local_sum" ]; then
    ok "이미지 안 시나리오 = 작업 폴더 파일"
  else
    bad "이미지 안 시나리오가 작업 폴더 파일과 다름 — 예전 설정으로 돌게 됨"
    hint "docker build -f orchestrator/Dockerfile -t $RUNNER_IMAGE . && minikube image load $RUNNER_IMAGE -p $CLUSTER_NAME"
  fi
fi

# 결과 ----------------------------------------------------------------
echo | tee -a "$OUT"
echo "PASS $pass / WARN $warn / FAIL $fail   ($OUT)" | tee -a "$OUT"
if [ "$fail" -gt 0 ]; then
  echo "FAIL을 고친 뒤 다시 점검하세요. 이 상태로 돌린 run은 판정에 이전 run이 섞이거나 설정이 다를 수 있습니다."
  exit 1
fi
echo "시작해도 됩니다: bash infra/local/run-scenario.sh $SCENARIO  (실행 후 이 점검 결과 파일을 run 결과와 함께 보관)"
