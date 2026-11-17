# broker 시나리오 부하 테스트 (w4 회의록 4번)

- 일시: 2026-11-16 23:55 ~ 2026-11-17 00:20
- 담당: E
- 환경: minikube 2노드(각 2CPU·3GB), `ORDER_MODE=adapter bash infra/local/up.sh --with-apps` (Prometheus·Chaos Mesh 포함)
- 시나리오: `experiments/scenarios/broker-baseline.yaml`, `broker-delay.yaml`, `broker-partition.yaml` (이 브랜치)
- 기록: run마다 `infra/local/backlog-watch.sh`로 10초 간격 주문 상태 수 기록, 판정은 실행기 `runs/<run_id>/report.md`

## 결론

1. **rate 0.8건/s를 broker 시나리오 부하로 확정 가능하다.**

   장애가 없을 때 1.6건/s까지 pending이 쌓이지 않는다(정산 처리량 ≥ 1.6건/s).
   → broker 실험 중 늘어난 pending은 처리 지연이 아니라 장애 때문이라고 구분할 수 있다.
2. **delay·partition 모두 장애 중 적체가 쌓였다가 복구 후 30초 안에 빠졌다.**

   실행기 drain 판정 `queue_drained`, unknown 0.
3. **정합성은 두 run 모두 PASS**(유실·불일치·중복·고아·잔고·미정산 0).
4. **최종 판정은 INCONCLUSIVE**

   원인은 장애가 아니라 증거 부족이다. 구간이 짧고(warmup 30초) 계좌 수(300)에 비해 주문이 적다.
   해소 방법은 아래 [다음 단계](#다음-단계)에 정리했다.

## 1. 적체 (backlog-watch.sh)

| run | run_id | 부하 | pending | 장애 중 정산 속도 | 비고 |
|---|---|---|---|---|---|
| baseline 0.8 | `r-1116235618` | 0.8건/s, 약 400초 | 내내 0~1 | — (평소 0.7~0.9건/s) | 적체 없음 |
| baseline 1.6 | `r-1117000520` | 1.6건/s, 약 400초 (filled 616 + rejected 55) | 내내 0~3 | — (평소 1.1~1.9건/s) | 적체 없음 |
| delay 2초 | `r-1117001423` | 0.8건/s | 장애 시작 후 증가, **최대 37** → 복구 후 약 30초에 0 | **0.0~0.2건/s** | unknown 0 |
| partition 30초 | `r-1117001747` | 0.8건/s | 장애 시작 후 증가, **최대 24** → 복구 후 약 20초에 0 | **0.0건/s** | unknown 0, 복구 직후 rejected +25 |

- delay·partition run은 drain이 빨리 끝나 실행기가 k6를 일찍 멈췄다. 부하 시간은 약 125초다(`duration_s` 420은 상한).
- 첫 rate 1.6 측정은 예전 kind 클러스터가 함께 떠 있어 자원이 부족했다. kind를 지운 뒤 다시 잰 값이 위 표다.

## 2. 판정 (runs/<run_id>/report.md)

| run | 판정 | 정합성 | drain | INCONCLUSIVE 사유 |
|---|---|---|---|---|
| baseline 0.8 / 1.6 | INCONCLUSIVE | — | 없음(장애 없음) | 장애 구간이 없어 기대한 결과 |
| delay | INCONCLUSIVE | 모두 0 (99건 OK) | `queue_drained` | `LOW_FILL_COVERAGE`, `GENERATOR_LIMITED`, `LOW_SAMPLES` |
| partition | INCONCLUSIVE | 모두 0 (99건 OK) | `queue_drained` | `LOW_FILL_COVERAGE`, `GENERATOR_LIMITED`, `LOW_SAMPLES` |

가드별 값 (delay / partition):

| 가드·기준 | 값 | 기준 | 원인 |
|---|---|---|---|
| `fill_coverage` | baseline 23 / 21, tail 79 / 55 | 구간마다 100건 이상 | warmup 30초라 baseline 구간이 약 30초뿐이다. 0.8건/s × 30초 ≈ 24건 |
| `load_coverage` | baseline 달성률 0.933 / 0.961 | 0.98 이상 | k6 자원 부족이 아니다. 표본 24건짜리 짧은 구간이라 1~2건 차이로 비율이 흔들렸다 |
| `sell_coverage` | 매도 체결 0 / 0 | 20건 이상 | 계좌 300개에 주문 99건(계좌당 약 0.3건)이라 보유가 쌓인 계좌가 없어 매도가 체결되지 않는다 |
| `order_p95_k6`, `order_err_k6` | baseline·tail 값 없음 | 구간 표본 부족 (`LOW_SAMPLES`) | 위와 같음 |

## 3. 함께 발견한 것

| 발견 | 내용 | 확인할 파트 |
|---|---|---|
| 증권사 2초 지연 시 정산 급감 | 지연은 2초(시간 초과 5초보다 짧음)인데 정산 속도가 0~0.2건/s로 떨어졌다. 회의록의 "Pod당 0.11건/s"와 같은 수준이라, 그 실측도 증권사가 느린 조건이었을 가능성이 있다. 정산 경로의 순차 호출과 대기가 의심된다: adapter `POLL_SECONDS` 0.2초, 주문 서비스 외부 주문 worker의 처리마다 0.5초 대기(`ADAPTER_POLL_SECONDS`) | C, D |
| 복구 직후 rejected 급증 | partition 복구 순간 rejected가 25건 늘었다(delay 중에도 약 10건). 유실·중복은 아니다. 계좌당 주문이 적어 생긴 매도 거절, 또는 대기 중 시세가 오래된 주문의 거절로 보인다 | B, C |
| 실행기 Job 재시도 | INCONCLUSIVE·ABORTED로 끝난 run을 Job이 `backoffLimit: 3`으로 3번 더 시작해, 앞 run의 재시도가 뒤 run 시간과 겹쳤다(run마다 Error Pod 4개). 리허설에서는 `backoffLimit: 0`으로 바꿔 돌렸다 | A (회의록 5번) |
| 로컬 자원 | 예전 kind 클러스터 컨테이너가 남아 CPU 약 1.8코어를 쓰고 있어 minikube API 서버가 멈췄다. 정리: `docker rm -f chaos-lab-control-plane chaos-lab-worker` | 전체 |

## 다음 단계

| 할 일 | 파트 |
|---|---|
| 시나리오 durations를 판정 구간에 맞춤(warmup 215 / recover 185). baseline 150초 → 0.8건/s × 150초 = 120건으로 `min_filled` 100을 넘음 | E (회의록 3번과 함께) |
| broker 시나리오 `load.accounts` 300 → 30 정도로 줄여 매도 체결 확보 (`sell_coverage`) | E |
| `broker.yaml`: 0.8건/s 기준으로 `min_filled`·달성률 기준 조정 여부, 복구 직후 rejected를 어떻게 셀지 | B |
| drain 최대 대기: 두 시나리오 모두 30초 안에 빠짐 → 현재 `timeout_s: 300`으로 충분 | A |
| 증권사 지연 시 정산 처리량 원인 확인 | C, D |

## 재현 방법

```bash
# 환경
ORDER_MODE=adapter bash infra/local/up.sh --with-apps
docker build -f orchestrator/Dockerfile -t chaos-orchestrator:dev .
minikube image load chaos-orchestrator:dev -p chaos-lab
kubectl --context chaos-lab apply -f orchestrator/k8s/rbac.yaml -f orchestrator/k8s/pvc.yaml

# run마다
bash infra/local/reset-db.sh -y
bash infra/local/backlog-watch.sh            # 터미널 A
RUN_ID=r-$(date +%m%d%H%M%S)                 # 터미널 B
sed -e "s/__RUN_ID__/$RUN_ID/" \
    -e "s#scenarios/pod-kill.yaml#scenarios/broker-delay.yaml#" \
    -e "s/backoffLimit: 3/backoffLimit: 0/" \
    orchestrator/k8s/job.yaml | kubectl --context chaos-lab apply -f -
kubectl --context chaos-lab -n exchange logs -f job/chaos-run-$RUN_ID
```
