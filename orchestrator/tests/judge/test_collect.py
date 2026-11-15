"""collect(gather.py, 설계 5.2): 가짜 kubectl·psql로 돈다(클러스터 없음).

fetch·release는 fetch 모듈 함수를 바꿔 끼운다. 증거 폴더는 run_ok 픽스처 복사본이다.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from dataclasses import replace
from pathlib import Path

import pytest

from orchestrator.judge import fetch as fetch_mod
from orchestrator.judge import gather
from orchestrator.judge.context import load_run
from orchestrator.judge.criteria import RESOLVED_NAME, load_criteria
from orchestrator.judge.db import parse_bundle_output, render_snapshot, run_key_regex
from orchestrator.judge.fetch import FetchResult, PodStatus
from orchestrator.judge.model import DbTarget, Outcome, sha256_bytes
from orchestrator.judge.pipeline import evaluate
from orchestrator.judge.transport import TransportError, Transports

FIXTURE = Path(__file__).parent / "fixtures" / "run_ok"
CRIT = load_criteria(FIXTURE / "criteria.yaml")
SNAPSHOT = (FIXTURE / "raw/db/snapshot.txt").read_text(encoding="utf-8")
T0 = 1_762_300_000_000  # 픽스처 run_start.t
K6_POD = "k6-r-offline-ok-abcde"


def _unquiet(text: str) -> str:
    """F2만 바꾼 스냅샷(F1 ≠ F2, 늦은 커밋)."""
    db = parse_bundle_output(text)
    fp2 = replace(db.fingerprint2, orders=db.fingerprint2.orders + 1)
    return render_snapshot(replace(db, fingerprint2=fp2))


def _iso(ms: int) -> str:
    from datetime import datetime, timezone

    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def _pod(name: str, created: int, *, ready=True, crash_at: int | None = None) -> dict:
    cs = {"name": "order"}
    if crash_at is not None:
        cs["lastState"] = {"terminated": {"exitCode": 1, "finishedAt": _iso(crash_at)}}
    return {
        "metadata": {"name": name, "creationTimestamp": _iso(created)},
        "status": {
            "conditions": [{"type": "Ready", "status": "True" if ready else "False"}],
            "containerStatuses": [cs],
        },
    }


class Cluster:
    """가짜 runner. psql은 pending 조회면 pending 수(다 쓰면 0, None은 psql 실패)를,
    bundle이면 snapshots를 차례로 돌려준다. get pods는 pods를 돌려준다."""

    def __init__(self, snapshots, pods=(), *, pods_rc=0, psql_error=False, pending=()):
        self.snapshots = list(snapshots)
        self.pods = list(pods)
        self.pods_rc = pods_rc
        self.psql_error = psql_error
        self.pending = list(pending)
        self.pending_runs: list[tuple] = []  # (argv, SQL)
        self.calls: list[str] = []

    def __call__(self, argv, *, input=None, timeout):
        if "psql" in argv:
            settle = b"pending=" in input
            self.calls.append("pending" if settle else "psql")
            if self.psql_error:
                raise TransportError("kubectl: 실행 파일을 찾을 수 없다")
            if settle:
                self.pending_runs.append((argv, input.decode()))
                n = self.pending.pop(0) if self.pending else 0
                if n is None:
                    return subprocess.CompletedProcess(argv, 1, b"", b"ERROR")
                return subprocess.CompletedProcess(
                    argv, 0, f"pending={n}\n".encode(), b""
                )
            out = self.snapshots.pop(0).encode("utf-8")
            return subprocess.CompletedProcess(argv, 0, out, b"")
        assert argv[-6:] == ("get", "pods", "-l", gather.ORDER_SELECTOR, "-o", "json")
        self.calls.append("pods")
        if self.pods_rc:
            return subprocess.CompletedProcess(argv, self.pods_rc, b"", b"forbidden")
        body = json.dumps({"items": self.pods}).encode("utf-8")
        return subprocess.CompletedProcess(argv, 0, body, b"")


def _fault_marks(run_dir: Path) -> None:
    """장애 구간 T0+4s–T0+5s를 run.json에 넣는다."""
    doc = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
    doc["marks"] = {
        **doc.get("marks", {}),
        "inject_start": T0 + 4000,
        "inject_end": T0 + 5000,
    }
    (run_dir / "run.json").write_text(json.dumps(doc), encoding="utf-8")


@pytest.fixture
def run(tmp_path, monkeypatch):
    """run_ok 복사본. fetch는 기록이 이미 있다고 보고 Pod 이름만 돌려준다."""
    dst = tmp_path / "run_ok"
    shutil.copytree(FIXTURE, dst)
    calls: list[str] = []

    def fake_fetch(ctx, tr, run_dir):
        calls.append("fetch")
        return FetchResult(
            pod=K6_POD, k6_dir=run_dir / "k6", pod_status=PodStatus(K6_POD)
        )

    monkeypatch.setattr(fetch_mod, "fetch", fake_fetch)
    monkeypatch.setattr(
        fetch_mod, "release", lambda tr, pod: calls.append(f"release {pod}")
    )
    return dst, calls


def _collect(run_dir: Path, cluster: Cluster, sleeps: list[float]) -> Path:
    ctx = load_run(run_dir / "run.json")
    return gather.collect(ctx, CRIT, Transports(runner=cluster), sleep=sleeps.append)


def test_collect_writes_evidence_and_judges_pass(run):
    run_dir, calls = run
    cluster, sleeps = Cluster([SNAPSHOT], [_pod("order-a", T0 - 60_000)]), []
    assert _collect(run_dir, cluster, sleeps) == run_dir

    assert calls == ["fetch", f"release {K6_POD}"]  # RELEASE는 DB·Pod 관측 뒤
    assert cluster.calls == ["pending", "psql", "pods"]
    assert sleeps == [gather.QUIET_S]  # pending이 처음부터 0이면 더 기다리지 않는다
    assert (run_dir / "raw/db/snapshot.txt").read_text(encoding="utf-8") == SNAPSHOT
    assert not (run_dir / "raw/db/psql-stderr.txt").exists()
    obs = json.loads((run_dir / "raw/k8s/obs.json").read_text(encoding="utf-8"))
    assert (
        "pod_replaced" not in obs and "note" in obs
    )  # 장애 없는 run이라 inject_start가 없다
    assert (run_dir / RESOLVED_NAME).read_text(encoding="utf-8") == CRIT.text

    files = json.loads((run_dir / "evidence.json").read_text(encoding="utf-8"))["files"]
    assert {
        "k6/orders.jsonl",
        "raw/db/snapshot.txt",
        "raw/k8s/pods.json",
        RESOLVED_NAME,
    } <= set(files)
    assert files["raw/k8s/obs.json"] == sha256_bytes(
        (run_dir / "raw/k8s/obs.json").read_bytes()
    )
    assert list(files) == sorted(files)

    v = evaluate(load_run(run_dir / "run.json"), CRIT, run_dir)
    assert v.verdict is Outcome.PASS


def test_fault_run_writes_pod_observation(run):
    run_dir, _ = run
    _fault_marks(run_dir)
    pods = [_pod("order-a", T0 - 60_000), _pod("order-b", T0 + 6000)]
    _collect(run_dir, Cluster([SNAPSHOT], pods), [])
    obs = json.loads((run_dir / "raw/k8s/obs.json").read_text(encoding="utf-8"))
    assert obs["pod_replaced"] == 1 and obs["crash_restart"] == 0
    assert json.loads((run_dir / "raw/k8s/pods.json").read_bytes())["items"] == pods


def test_db_not_quiescent_retries_once(run):
    run_dir, _ = run
    cluster, sleeps = Cluster([_unquiet(SNAPSHOT), SNAPSHOT]), []
    _collect(run_dir, cluster, sleeps)
    assert cluster.calls == ["pending", "psql", "psql", "pods"]
    assert sleeps == [gather.QUIET_S, gather.RETRY_S]
    assert (run_dir / "raw/db/snapshot.txt").read_text(encoding="utf-8") == SNAPSHOT

    still = Cluster(
        [_unquiet(SNAPSHOT)] * 3
    )  # 두 번째도 다르면 더 찍지 않는다(db_quiescent 몫)
    _collect(run_dir, still, [])
    assert still.calls == ["pending", "psql", "psql", "pods"]


@pytest.mark.parametrize(
    "pending, polls, waits",
    [
        ([3, 1, 0], 3, 2),
        ([0], 1, 0),
        ([None], 1, 0),  # psql 실패·출력을 못 읽으면 기다리지 않는다
        ([7] * 40, 36, 36),  # 180초(5초 × 36)가 지나면 그대로 스냅샷
    ],
)
def test_waits_for_pending_orders_before_snapshot(run, pending, polls, waits):
    run_dir, _ = run
    cluster, sleeps = Cluster([SNAPSHOT], pending=pending), []
    _collect(run_dir, cluster, sleeps)
    assert cluster.calls == ["pending"] * polls + ["psql", "pods"]
    assert sleeps == [gather.QUIET_S] + [gather.SETTLE_POLL_S] * waits


def test_pending_query_filters_this_run_on_run_db(run):
    run_dir, _ = run
    ctx = replace(load_run(run_dir / "run.json"), db=DbTarget(pod="pg-9"))
    cluster = Cluster([], pending=[2])
    assert gather._pending(ctx, Transports(runner=cluster)) == 2
    [(argv, sql)] = cluster.pending_runs
    assert "pg-9" in argv
    assert "status = 'pending'" in sql
    assert f"client_order_id ~ '{run_key_regex(ctx.run_id)}'" in sql


def test_psql_failure_keeps_going_without_snapshot(run):
    run_dir, calls = run
    (run_dir / "raw/db/snapshot.txt").unlink()
    sleeps: list[float] = []
    _collect(run_dir, Cluster([], psql_error=True), sleeps)
    assert sleeps == [gather.QUIET_S]  # pending 조회도 실패하면 기다리지 않는다
    assert not (run_dir / "raw/db/snapshot.txt").exists()  # evaluate가 DB_ERROR로 본다
    assert "실행 파일" in (run_dir / "raw/db/psql-stderr.txt").read_text(
        encoding="utf-8"
    )
    assert calls[-1] == f"release {K6_POD}"


def test_pod_query_failure_is_recorded(run):
    run_dir, _ = run
    _collect(run_dir, Cluster([SNAPSHOT], pods_rc=1), [])
    obs = json.loads((run_dir / "raw/k8s/obs.json").read_text(encoding="utf-8"))
    assert obs["error"] == "forbidden" and "pod_replaced" not in obs
    assert not (run_dir / "raw/k8s/pods.json").exists()


def test_pod_counts_same_second_replacement():
    # 실제 kind run에서 나온 경우: 05:53:57.606에 지웠고 교체 Pod 시각은 05:53:57Z다
    pods = [_pod("new", T0 + 900), _pod("crash", T0 - 60_000, crash_at=T0 + 900)]
    got = gather.pod_counts(pods, T0 + 606, T0 + 10_000)
    assert got == {"pod_replaced": 1, "crash_restart": 1}


def test_pod_counts_rules():
    start, end = T0, T0 + 30_000
    pods = [
        _pod("old", start - 1000),  # 장애 전에 있던 Pod
        _pod("new", start + 5000),  # 교체됨
        _pod("late", start + 200_000),  # 교체는 맞지만 within_s 밖
        _pod("not-ready", start + 5000, ready=False),
        _pod("crash-in", start - 1000, crash_at=start + 1000),
        _pod("crash-out", start - 1000, crash_at=end + 1000),
    ]
    assert gather.pod_counts(pods, start, end) == {
        "pod_replaced": 2,
        "crash_restart": 1,
    }
    assert gather.pod_counts(pods, start, end, 120_000)["pod_replaced"] == 1
    assert (
        gather.pod_counts(pods, start, None)["crash_restart"] == 2
    )  # 끝 표지가 없으면 열린 구간
    assert "pod_replaced" not in gather.pod_counts(
        pods, None, None
    )  # inject_start 없음


def test_within_s_comes_from_fault_effect(tmp_path):
    p = tmp_path / "crit.yaml"
    p.write_text(
        f"extends: {FIXTURE / 'criteria.yaml'}\n"
        "fault_effect: [{id: pod_replaced, observe: pod_replaced, target: order-api, within_s: 120}]\n",
        encoding="utf-8",
    )
    crit = load_criteria(p)
    assert gather._within_ms(crit, "pod_replaced") == 120_000
    assert gather._within_ms(crit, "crash_restart") is None
