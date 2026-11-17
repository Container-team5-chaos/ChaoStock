유실 0 · 불일치 0 · 중복 0 · 고아 0 · 잔고 불일치 0 · 신선도 위반 체결 0 → PASS
커밋 후 회수 0건(after_commit)

## 판정: PASS

- run_id: `r-1117095921` · 실험: `pod-kill`
- 사유: 없음
- 경고: 없음

### 주문

| 항목 | 건수 |
| --- | ---: |
| 의도(intent) | 13910 |
| ACK(200·202·422 replay, order_id) | 13910 |
| 유실(LOST+REJECT_COMMITTED) | 0 |
| 내용 불일치(MISMATCH+BODY_MISMATCH) | 0 |
| 중복(DUP_ORDER+FILL_STATE+IDEMPOTENCY_VIOLATION) | 0 |
| 고아(ORPHAN) | 0 |
| 결과 불명·중단(사용자 영향: UNRESOLVED_COMMITTED+UNRESOLVED_ABSENT+INTERRUPTED) | 0 |
| 미정산(UNSETTLED) | 0 |
| 기록 완전성(log_complete) | 예 |

클래스별: OK 13910

### 잔고와 신선도

| 항목 | 위반 |
| --- | ---: |
| 잔고 불일치(cash 0, qty 0, avg 0) | 0 |
| 신선도 위반 체결(fresh) | 0 |

그 밖 불변식: arith 0, constraints 0, nonneg 0

### 커밋 후 회수

커밋 후 회수 0건(after_commit)

| OK 세부 | 건수 |
| --- | ---: |
| clean | 13798 |
| after_commit | 0 |
| not_committed | 112 |
| after_503 | 0 |
| rejected | 0 |

### 구간 p95(k6 기록, nearest-rank)

| 구간 | n | ack p95(ms) | 첫 시도 오류율 | 달성률 |
| --- | ---: | ---: | ---: | ---: |
| warmup | 1673 | 287.54611 | 0.057382 | 0.929444 |
| baseline | 4440 | 14.032578 | 0.000000 | 1.000000 |
| fault | 3638 | 15.581358 | 0.000000 | 0.999881 |
| recovery | 3755 | 12.988252 | 0.000000 | 1.000253 |
| tail | 3600 | 12.994848 | 0.000000 | 1.000000 |

### 기준과 가드

| 구분 | id | 종류 | 결과 | 필수 | 값 | 사유 |
| --- | --- | --- | --- | --- | ---: | --- |
| 기준 | `lost` | integrity | PASS | 예 | 0 | 없음 |
| 기준 | `mismatch` | integrity | PASS | 예 | 0 | 없음 |
| 기준 | `duplicates` | integrity | PASS | 예 | 0 | 없음 |
| 기준 | `orphans` | integrity | PASS | 예 | 0 | 없음 |
| 기준 | `invariants` | integrity | PASS | 예 | 0 | 없음 |
| 기준 | `stale_fill` | integrity | PASS | 아니오(보고만) | 0 | 없음 |
| 기준 | `protocol` | unresolved | PASS | 예 | 0 | 없음 |
| 기준 | `unsettled` | unresolved | PASS | 예 | 0 | 없음 |
| 기준 | `order_p95_k6` | client | PASS | 예 | {"baseline":"14.032578","tail":"12.994848"} | 없음 |
| 기준 | `order_err_k6` | client | PASS | 예 | {"baseline":"0.000000","tail":"0.000000"} | 없음 |
| 기준 | `k6_exit` | k6 | PASS | 예 | 105 | 없음 |
| 기준 | `judge_self_check` | integrity | PASS | 아니오(보고만) | 0 | 없음 |
| 가드 | `safety` | guard | PASS | 예 | {"account_multi_vu":0,"bad_key":0,"bad_market":0,"bad_user"… | 없음 |
| 가드 | `account_set` | guard | PASS | 예 | {"extra":0,"extra_missing":0,"jsonl":300,"missing":0} | 없음 |
| 가드 | `fill_coverage` | guard | PASS | 예 | {"baseline":4440,"tail":3600} | 없음 |
| 가드 | `sell_coverage` | guard | PASS | 예 | 4812 | 없음 |
| 가드 | `load_coverage` | guard | PASS | 예 | {"baseline":"1.000000","tail":"1.000000"} | 없음 |
| 가드 | `fault_in_load` | guard | PASS | 예 | 0 | 없음 |
| 가드 | `fault_effect` | guard | N/A | 예 | — | 없음 |
| 가드 | `db_quiescent` | guard | PASS | 예 | {"f1":{"krw_sum":"9992147851.5093","max_order_id":13910,"or… | 없음 |
| 가드 | `log_complete` | log | PASS | 아니오(보고만) | 예 | 없음 |

### 증거 해시

- criteria_sha256: `a4a5c614c4a648f272668433ed01d52f8a7d0db27ad845370dc6c96b90c6b848`
- criteria_resolved_sha256: `dec71363b4dbf5f72a00dee30c4511e63929b0cd58cfe7cf08e722b37c4a8f25`
- run_json_sha256: `f65c98bb5ea4ec23bd3dc2074ce36e959be8b77db71495b835e88279e4c089f0`
- evidence_manifest_sha256: `6d720f6e754e18c3b656ded90ea32114db9e6e80ea9530b55e824ca0285bd285`
- judge_version: `0.1.0`
- response_fields_confirmed: `예`
- verdict_digest: `59ea8aaedc681378c5faaf87d81b5e7ddd6d05b19fb688d8fbe0bb2a39125f8e`
