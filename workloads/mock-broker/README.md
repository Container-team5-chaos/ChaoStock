# Mock broker

adapter가 호출하는 내부용 모의 증권사. Redis의 최신 KRW-BTC 가격으로 전량 체결하고,
결과를 PostgreSQL `mock_broker_orders`에 저장한다. 실제 증권사로 주문하지 않는다.
사용자·잔고·보유량 검사와 예약·정산은 기존 D 주문 서비스가 맡는다.

```text
주문 서비스 (예약·정산) → adapter (전달·재조회) → mock-broker (모의 체결)
                                                ├─ Redis: 현재가 읽기
                                                └─ PostgreSQL: 체결/거절 결과 보관
```

## API

내부 주소: `http://mock-broker.exchange.svc.cluster.local:8000`
금액·수량은 문자열. `/docs`, `/openapi.json`에서 요청 스키마를 확인할 수 있다.

| 경로 | 동작 |
| --- | --- |
| `POST /orders` | 처음 체결하면 201, 기존 결과 재반환이나 확정 거절은 200 |
| `GET /orders/{client_order_id}` | 저장된 결과 200, 기록이 없으면 404 |
| `GET /healthz` | 프로세스가 응답하면 200 |
| `GET /readyz` | DB 테이블·Redis 연결 정상이고 종료 중이 아니면 200, 아니면 503 |
| `GET /metrics` | Prometheus 지표 |

요청은 adapter의 주문 계약과 같다. `Idempotency-Key` 헤더는 생략 가능하나,
있으면 본문의 `client_order_id`와 같아야 한다.

```json
{"client_order_id":"demo-1","user_id":"user-0001","market":"KRW-BTC","side":"bid","volume":"0.001","max_amount":"98000"}
```

응답 예시(가격이 98,000,000원인 경우):

```json
{
  "client_order_id":"demo-1", "user_id":"user-0001", "market":"KRW-BTC",
  "side":"bid", "volume":"0.00100000", "max_amount":"98000.0000",
  "status":"filled", "broker_order_id":"broker-<uuid>",
  "fill_price":"98000000.00000000", "amount":"98000.0000",
  "filled_at":"2026-11-15T00:00:00+00:00"
}
```

- `volume`: 양수, 정수 22자리 미만 범위(`< 1e22`), 소수 최대 8자리.
- `max_amount`: 선택, 0 이상 `< 1e20`, 소수 최대 4자리. 응답에 동일한 한도를 돌려준다.
- `amount = fill_price × volume`, 소수 4자리 미만 버림. 수수료·부분 체결은 없다.
- 예약 한도 초과는 체결 없이 `status=rejected`, `reason=price_limit_exceeded`로 저장한다.
  한도가 있으면 매도에도 적용한다(adapter의 결과 검증과 동일).
- 금액이 D의 저장 범위를 넘으면 `amount_out_of_range`로 거절·저장한다.
- 시세는 문자열 양수 `< 1e16`, 소수 최대 8자리이며, 수신 시각 `ts`는 Unix 밀리초다.
  미래 시각·잘못된 형식은 유효한 현재가로 사용하지 않는다.

| HTTP | reason | 기록 여부 |
| --- | --- | --- |
| 400 | invalid_request | 없음 |
| 409 | idempotency_conflict | 기존 주문 유지 |
| 404 | order_not_found | 없음 |
| 429 | rate_limited | 새 주문을 만들지 않음. `Retry-After` 초 제공 |
| 503 | stale_price / price_unavailable | 새 주문을 만들지 않음. 같은 키로 재시도 |
| 503 | not_ready | DB/Redis 오류·종료 중. commit 결과가 불명확할 수 있어 같은 키로 조회·재시도 |

HTTP 오류는 `{ "status":"rejected", "reason":"...", "client_order_id":"..." }` 형식이다.
확정 거절(HTTP 200)은 원본 요청 필드·한도와 `status`, `reason`을 포함한다.
이 서비스는 자체적으로 즉시 판정하므로 `pending`을 저장하지 않는다.
주문 서비스와 adapter의 비동기 접수 상태는 기존대로 `pending`이다.

## 중복·응답 유실 처리

동일 주문 키를 DB 트랜잭션 잠금으로 직렬화하고 결과를 한 번만 저장한다.
동일 내용의 재요청은 가격을 다시 읽지 않고 최초 결과(체결 시각·번호 포함)를 그대로 돌려준다.
수량과 한도는 정규화하여 비교하며 내용이 다르면 409다. 확정 거절도 같은 키로 뒤집히지 않는다.

DB commit 이후 응답하므로, 응답 유실이나 Pod 재시작 뒤에도 GET으로 결과를 찾을 수 있다.
DB commit 전에 중단되면 결과가 남지 않으며 같은 키로 재시도할 수 있다.
별도의 실제 거래를 실행하지 않으므로 여기서 결과 저장이 모의 체결의 확정 시점이다.

기존 accounts/orders/positions/ticks/adapter_orders 테이블은 변경하지 않는다.
초기화 명령은 새 `mock_broker_orders` 테이블만 생성하고 기존 기록을 보존한다.
`reset-db.sh`는 이 테이블을 비우지 않으므로 실험마다 새로운 주문 키/run_id를 사용한다.

## 로컬 minikube 배포

WSL/Bash, 저장소 루트에서 실행한다. DB·Redis 및 현재가가 준비돼 있어야 한다.

```bash
# mock-broker만 빌드·배포 (현재 주문 서비스 모드는 바꾸지 않음)
bash workloads/mock-broker/deploy-local.sh

# 전체 외부 주문 흐름을 띄울 때: 기존 up.sh가 새 배포 스크립트를 호출한다
ORDER_MODE=adapter PRICE_STUB=0 bash infra/local/up.sh --with-apps

kubectl --context chaos-lab -n exchange port-forward svc/mock-broker 8002:8000
curl http://localhost:8002/readyz
```

단독 POST는 D의 잔고를 변경하지 않는다. 전체 정산 검증은 **주문 서비스**의
`POST /orders` → `GET /orders/{client_order_id}` → `GET /accounts/{user_id}`로 진행한다.
기존 k6는 202 접수/최종 상태 조회 대응이 별도로 필요하다.

이미지는 필요한 파일만 tar로 빌드하여 WSL/Windows 캐시의 xattr 오류를 피한다.
Helm initContainer가 스키마를 초기화하고, 기존 `postgres` Secret을 사용한다.
기본 단일 replica/Recreate이며 `app=mock-broker` 라벨이 기존 Chaos 시나리오와 일치한다.
모니터링 CRD가 없는 환경에서는 배포 인자 `--set serviceMonitor.enabled=false`를 추가한다.

## 설정과 장애 재현

| 환경변수 | 기본값 | 의미 |
| --- | --- | --- |
| DATABASE_URL | 없음 | 또는 POSTGRES_USER/PASSWORD/DB + PGHOST/PGPORT로 구성 |
| REDIS_URL | redis://redis:6379/0 | 최신가 조회 |
| STALE_MS | 5000 | 이 시간 이상 오래된 시세는 503 |
| DB_POOL_SIZE | 5 | 프로세스당 DB 연결 수 |
| RESPONSE_DELAY_SECONDS | 0 | 주문 POST/GET 응답 지연. POST는 **commit 후** 지연 |
| RATE_LIMIT_RPS | 0 | 0은 제한 없음. 양수는 GET/POST 합산 프로세스당 호출 간격 제한 |
| PORT | 8000 | HTTP 포트 |

```bash
# adapter 기본 타임아웃 5초보다 긴 응답 지연 (자동 unknown까지 갈 수 있음)
bash workloads/mock-broker/deploy-local.sh --set config.responseDelaySeconds=6
# 429 재현 (GET 조회와 POST가 모두 호출 수에 포함됨)
bash workloads/mock-broker/deploy-local.sh --set config.rateLimitRps=2
# 정상 설정으로 복귀
bash workloads/mock-broker/deploy-local.sh
```

readiness/liveness/metrics에는 지연·호출 제한을 적용하지 않는다.
장시간 지연을 계속 유지하면 조회도 늦어져 adapter는 최대 시도 후 unknown이 될 수 있다.
기존 `broker-delay.yaml`, `broker-partition.yaml`의 NetworkChaos로도 실험할 수 있다.
정상 반환 복구 검증은 장애를 해제한 뒤 같은 키로 조회한다.

지표: `mock_broker_orders_total{status}`, `mock_broker_replayed_total`,
`mock_broker_rate_limited_total`. 프로세스 재시작 시 초기화되며 결과의 원본은 DB다.
내부 테스트 서비스이며 사용자 인증과 실제 증권사 기능은 포함하지 않는다.

## 테스트

```bash
cd workloads/mock-broker
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
python -m pytest -q

# 전용 테스트 DB 권장. 테스트마다 임시 schema를 생성·삭제하며 기존 테이블은 건드리지 않음
MOCK_BROKER_TEST_DATABASE_URL=postgresql://test:test@localhost:15433/test python -m pytest -q
```

API·금액 계산·예약 한도·429·응답 유실 및 기존 adapter/D 응답 검증 코드를 검사한다.
DB 통합 테스트는 동시 요청, 초기화 재실행, 애플리케이션 재생성, commit 이후 응답 유실을 확인한다.
테스트 DB 주소가 없으면 DB 테스트만 skip된다.
