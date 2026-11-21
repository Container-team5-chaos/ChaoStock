# 운
- 환경: minikube 2노드(각 2CPU·3GB), main `9f63457`(#52 운영 절차 반영), Prometheus·Chaos Mesh 포함
- 절차: [`docs/operations.md`](../operations.md) 그대로 run 두 번을 연달아 실행. 두 번째 run은 주문 모드가 다른 시나리오로 골라 모드 전환까지 확인

## 결론

1. **운영 절차대로 run 두 번이 끊김 없이 돌았다.** broker-delay(adapter 모드) → pod-kill(baseline 모드) 모두 PASS, `cleanup=OK`.
2. **11/17 무효 run의 원인 세 가지가 모두 막혔다.**
   - 이전 주문이 섞인 판정 → `reset-db.sh -y --force`
   - 잘못된 주문 모드 → `preflight.sh`가 시작 전에 막음
   - 예전 실행기 이미지 → `preflight.sh` 6번 점검
3. **문서 보완 두 가지:** 주문 모드 전환 단계와 끝난 Job 정리를 `docs/operations.md`에 추가했다.

→ 회의록 6번 "이전 결과 수집 → 실험 DB 초기화 → 주문 모드 확인 → 다음 run 실행 순서를 공통 운영 절차로 확정"을 충족한다.

## 1. 진행 순서와 결과

| # | 절차 (`docs/operations.md`) | 명령 | 결과 |
|---|---|---|---|
| 0 | 3. 실행기 이미지 (#50·#52로 실행기 코드와 `job.yaml`이 바뀜) | `docker build …` + `minikube image load …` | 완료 |
| 1 | 1. 이전 결과 꺼내기 | `fetch-run.sh --list` | PVC의 run 목록 확인 |
| 2 | 2. DB 초기화 | `reset-db.sh -y --force` | `accounts=1000` |
| 3 | 4. 점검 → 실행 (broker-delay) | `run-scenario.sh broker-delay` | preflight 통과 → Job → 로그 → **PASS**, 결과 자동 꺼냄 |
| 4 | 1. 이전 결과 꺼내기 | `ls runs/` | `runs/r-1121165147/` 있음 |
| 5 | 2. DB 초기화 | `reset-db.sh -y --force` | 주문·계좌와 함께 `adapter_orders`, `mock_broker_orders`까지 비움, `accounts=1000` |
| 6 | 4. 점검 → 실행 (pod-kill) | `run-scenario.sh pod-kill` | **preflight FAIL(주문 모드 불일치)로 시작 안 함** (의도한 동작) |
| 7 | (문서에 없음) 주문 모드 전환 | `deploy-local.sh` (baseline) | 완료 |
| 8 | 2. DB 초기화 | `reset-db.sh -y --force` | `accounts=1000` |
| 9 | 4. 점검 → 실행 (pod-kill) | `run-scenario.sh pod-kill` | **PASS**, 결과 자동 꺼냄 |

## 2. run 결과

| 항목 | broker-delay `r-1121165147` | pod-kill `r-1121172006` |
|---|---|---|
| 주문 모드 | adapter | baseline |
| 실행기 결과 (`state.json`) | `result=PASSED`, `cleanup=OK` | `result=PASSED`, `cleanup=OK` |
| 판정 (`report.md`) | PASS (정합성 위반 0) | PASS (정합성 위반 0) |
| 장애 효과 | `run.json`에 `inject_start`, `inject_end`, `queue_drained` | `raw/k8s/obs.json`의 `pod_replaced: 1` → 가드 `pod_replaced` **PASS** |
| 꺼낸 파일 (`runs/<run_id>/`) | `run.json`, `state.json`, `report.md`, `verdict.json`, `classified.csv`, `criteria.resolved.yaml`, `evidence.json`, `k6/`, `raw/` | 같음 |

- pod-kill은 #42로 기준 파일이 연결돼, 11/17 리허설의 `fault_effect: N/A`가 이번에는 `pod_replaced` PASS로 판정됐다. 이제 PASS가 "Pod가 실제로 교체됐다"까지 보장한다(회의록 3번).
- 실행기 Job 재시도 점검은 #50 반영 후 PASS다(`--exit-zero-on-result`).

## 3. 리허설에서 나온 보완점

| 발견 | 내용 | 조치 |
|---|---|---|
| 주문 모드 전환 단계가 문서에 없음 | preflight가 막고 고칠 명령도 알려 주지만, 절차 흐름에 "시나리오 모드에 맞춰 주문 서비스 다시 배포"가 없다 | `docs/operations.md`에 **1-1. 주문 모드 맞추기** 추가 (시나리오별 모드 표, 확인 명령, 모드를 바꾼 뒤 DB 초기화부터) |
| 끝난 Job이 쌓임 | `run-scenario.sh`는 결과를 꺼낸 뒤 Job을 지우지 않아, run마다 끝난 실행기·k6 Job이 늘어 preflight WARN이 된다(리허설 중 8개) | `docs/operations.md` 1번에 결과를 꺼낸 뒤 Job을 정리하는 명령 추가. `run-scenario.sh`가 꺼낸 뒤 자동으로 지울지는 A가 판단 |

## 재현

```bash
docker build -f orchestrator/Dockerfile -t chaos-orchestrator:dev . && minikube image load chaos-orchestrator:dev -p chaos-lab

bash infra/local/reset-db.sh -y --force
bash infra/local/run-scenario.sh broker-delay          # 주문 서비스 adapter 모드

bash workloads/order/deploy-local.sh                   # baseline 모드로 전환
bash infra/local/reset-db.sh -y --force
bash infra/local/run-scenario.sh pod-kill
```
