# 실험 운영 절차

장애 실험 run 하나를 돌릴 때마다 아래 순서를 지킨다. 11/17 리허설에서 앞 run의 미정산 주문이 남은 채로 다음 run을 돌려
이전 주문 3,749건이 섞여 판정된 무효 run이 나왔다. 그 재발을 막는 것이 이 문서의 목적이다.

```
이전 결과 꺼내기 → DB 초기화 → (코드를 바꿨으면) 실행기 이미지 다시 넣기 → 점검 → 실행 → 결과 꺼내기
```

## 어디서 무엇이 도나

| 무엇 | 어디서 | 비고 |
|---|---|---|
| 장애 실험 (k6 → 장애 주입 → 판정) | minikube `chaos-lab`, namespace `exchange` | EKS는 접속·주문 흐름 시연만 (11/16 회의 1번) |
| 실행기 | minikube 안의 **Job** (`chaos-run-<run_id>`) | 실행기 Pod가 죽어도 Job이 다시 띄워 정리한다 (시나리오 5-b) |
| 실행기 기록 | PVC `chaos-orchestrator-state`의 `/var/lib/orchestrator/` | `state.json` 하나 + `runs/<run_id>/` |
| 결과 보관 | 노트북 저장소의 `runs/<run_id>/` (gitignore) | 대표 run만 `docs/results/`에 커밋 |

run별 파일 목록은 [`docs/design/b-measure-judge.md` 7.6](design/b-measure-judge.md)에 있다.

## 1. 이전 결과 꺼내기

DB를 지우기 **전에** 앞 run의 결과가 노트북에 있는지 확인한다. 판정에 쓰는 DB 스냅샷은 실행기가 run 끝에 이미 떠 두므로,
`runs/<run_id>/`가 있으면 DB를 지워도 다시 판정할 수 있다.

```bash
bash infra/local/fetch-run.sh --list          # PVC에 있는 run
bash infra/local/fetch-run.sh r-1121093000    # → runs/r-1121093000/
```

`run-scenario.sh`로 돌렸으면 끝날 때 자동으로 꺼내져 있다.

## 2. DB 초기화

```bash
bash infra/local/reset-db.sh -y            # 미정산 외부 주문이 있으면 거부
bash infra/local/reset-db.sh -y --force    # 미정산 주문까지 버리고 초기화 (1번을 끝낸 뒤에만)
```

- 주문·포지션·계좌를 지우고 계좌 1,000개 × 1,000만 원으로 다시 채운다.
- adapter 대기열(`adapter_orders`)과 mock 증권사 기록(`mock_broker_orders`)도 함께 비운다.
- 실험 진행 중(Chaos 리소스나 실행 중 k6 Job이 있음)이면 `--force`여도 거부한다.

## 3. 실행기 이미지 (코드·시나리오를 바꿨을 때만)

실행기는 이미지 안의 시나리오 파일을 읽는다. 작업 폴더만 고치고 이미지를 안 넣으면 예전 설정으로 돈다(11/17 무효 run의 두 번째 원인).

```bash
docker build -f orchestrator/Dockerfile -t chaos-orchestrator:dev .
minikube image load chaos-orchestrator:dev -p chaos-lab
```

## 4. 점검 → 실행

```bash
bash infra/local/run-scenario.sh pod-kill
bash infra/local/run-scenario.sh broker-delay
```

`run-scenario.sh`가 하는 일:

1. `preflight.sh <시나리오>` — FAIL이 하나라도 있으면 시작하지 않는다
   - 주문 모드: 시나리오 `order_mode`(baseline / adapter)와 클러스터 주문 서비스 모드가 같은지
   - DB 초기 상태, adapter 대기열, 시세 신선도, 남은 Chaos·Job, 실행기 이미지 안 시나리오 = 작업 폴더 파일
2. 실행기 권한(RBAC)·PVC 적용 (이미 있으면 그대로)
3. `orchestrator/k8s/job.yaml`에 `RUN_ID`와 시나리오를 넣어 Job 적용
4. 로그를 따라가고, Job이 끝나면 `fetch-run.sh`로 결과를 `runs/<run_id>/`로 꺼낸다

`RUN_ID`를 정하고 싶으면 `RUN_ID=r-demo1 bash infra/local/run-scenario.sh pod-kill`.

## 5. 결과 확인

| 파일 | 볼 것 |
|---|---|
| `runs/<run_id>/state.json` | 실행기 결과 `result`(PASSED / FAILED / INCONCLUSIVE / ABORTED), `cleanup`(OK / INCOMPLETE), 중단 이유 |
| `runs/<run_id>/run.json` | 장애 주입 시각 `marks.inject_start`·`inject_end`, 대기열이 빠진 시각 `marks.queue_drained` |
| `runs/<run_id>/report.md` | 판정 요약 (사람용) |
| `runs/<run_id>/raw/k8s/obs.json` | Pod 교체 여부 `pod_replaced` |

- `cleanup=INCOMPLETE`면 장애가 남아 있을 수 있다. 다음 run은 실행기 시작 게이트에서 막힌다.
  `kubectl --context chaos-lab -n exchange get podchaos,networkchaos`로 확인하고 정리한다.
- 다시 판정: `python -m orchestrator.judge evaluate --run runs/<run_id>/run.json`

## 실행기가 시작하지 않을 때

| 메시지 | 원인 | 할 일 |
|---|---|---|
| `another_run_active: <run_id>` | 다른 run이 끝나지 않은 기록이 남아 있음 | 그 run의 Job이 아직 돌고 있으면 기다린다. 끊긴 거면 `bash infra/local/recover.sh` |
| `previous_cleanup: 이전 run ... 정리 미완료` | 직전 run의 장애 정리 실패 | `bash infra/local/recover.sh` (정리를 다시 시도한다) |
| `no_leftover_chaos: 남은 Chaos [...]` | `chaos/run-id` 라벨이 붙은 Chaos 리소스가 남음 | 지운 뒤 다시 실행 |
| `order_ready` / `adapter_ready` / `price_fresh` / `prometheus` | 서비스·시세·관측이 준비 안 됨 | `preflight.sh`의 해당 항목 안내대로 |
