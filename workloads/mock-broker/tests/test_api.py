import asyncio
import json
import time

import pytest
from redis.exceptions import ConnectionError as RedisConnectionError

from conftest import Cache, client_for


async def test_fill_replay_and_lookup_without_new_price(payload):
    cache = Cache()
    async with client_for(cache=cache) as (client, app):
        first = await client.post(
            "/orders", json=payload, headers={"Idempotency-Key": "test-1"}
        )
        assert first.status_code == 201
        body = first.json()
        assert body["amount"] == "98000.0000"
        assert body["max_amount"] == "98000.0000"
        assert body["volume"] == "0.00100000"
        cache.value = None  # Existing trades remain queryable without current prices.
        replay = await client.post("/orders", json={**payload, "volume": "0.00100000"})
        assert replay.status_code == 200 and replay.json() == body
        assert (await client.get("/orders/test-1")).json() == body
        assert cache.calls == 1
        conflict = await client.post("/orders", json={**payload, "side": "ask"})
        assert conflict.status_code == 409
        assert (await client.get("/orders/missing")).status_code == 404


async def test_budget_rejection_persists_even_if_price_changes(payload):
    cache = Cache()
    payload["max_amount"] = "1"
    async with client_for(cache=cache) as (client, app):
        result = await client.post("/orders", json=payload)
        assert result.status_code == 200
        assert result.json()["reason"] == "price_limit_exceeded"
        assert result.json()["max_amount"] == "1.0000"
        cache.value = None
        assert (await client.post("/orders", json=payload)).json() == result.json()


async def test_sell_and_rounding(payload):
    payload.pop("max_amount")
    payload.update(side="ask", volume="0.00000001")
    cache = Cache()
    cache.value = json.dumps(
        {"price": "12345678.12345678", "ts": int(time.time() * 1000)}
    )
    async with client_for(cache=cache) as (client, app):
        body = (await client.post("/orders", json=payload)).json()
        assert body["status"] == "filled"
        assert body["amount"] == "0.1234"
        assert "max_amount" not in body


@pytest.mark.parametrize(
    "raw,reason",
    [
        (None, "price_unavailable"),
        ("[]", "price_unavailable"),
        ('{"price":"NaN","ts":1}', "price_unavailable"),
        ('{"price":"98000000","ts":1}', "stale_price"),
        ('{"price":"98000000","ts":true}', "price_unavailable"),
        ('{"price":"98000000","ts":9999999999999999}', "price_unavailable"),
    ],
)
async def test_bad_price_does_not_create_order(payload, raw, reason):
    cache = Cache()
    cache.value = raw
    async with client_for(cache=cache) as (client, app):
        result = await client.post("/orders", json=payload)
        assert result.status_code == 503 and result.json()["reason"] == reason
        assert (await client.get("/orders/test-1")).status_code == 404
        cache.value = Cache().value
        assert (await client.post("/orders", json=payload)).status_code == 201


@pytest.mark.parametrize(
    "change",
    [
        {"volume": 0.001},
        {"volume": "0"},
        {"volume": "NaN"},
        {"volume": "1e22"},
        {"volume": "0.000000001"},
        {"max_amount": "-1"},
        {"max_amount": "1e20"},
        {"max_amount": "0.00001"},
        {"market": "KRW-ETH"},
        {"side": "buy"},
        {"extra": True},
        {"client_order_id": "bad/id"},
    ],
)
async def test_invalid_request(payload, change):
    async with client_for() as (client, app):
        assert (
            await client.post("/orders", json={**payload, **change})
        ).status_code == 400


async def test_header_mismatch_and_shutdown(payload):
    async with client_for() as (client, app):
        assert (
            await client.post(
                "/orders", json=payload, headers={"Idempotency-Key": "other"}
            )
        ).status_code == 400
        app.state.stopping = True
        assert (await client.post("/orders", json=payload)).status_code == 503
        assert (await client.get("/readyz")).status_code == 503
        assert (await client.get("/healthz")).status_code == 200


async def test_rate_limit_returns_retry_after_but_health_is_exempt(payload):
    async with client_for(rate_limit_rps=0.01) as (client, app):
        assert (await client.get("/orders/test-1")).status_code == 404
        result = await client.post("/orders", json=payload)
        assert result.status_code == 429
        assert int(result.headers["Retry-After"]) > 0
        assert not app.state.db.rows
        assert (await client.get("/readyz")).status_code == 200


async def test_lost_response_keeps_trade_for_retry(payload):
    async with client_for(response_delay=0.1) as (client, app):
        with pytest.raises(TimeoutError):
            await asyncio.wait_for(client.post("/orders", json=payload), timeout=0.03)
        stored = await app.state.db.get("test-1")
        assert stored["status"] == "filled"
        assert (await client.get("/orders/test-1")).json() == stored
        assert (await client.post("/orders", json=payload)).json() == stored


async def test_redis_failure_and_metrics(payload):
    class Down(Cache):
        async def get(self, key):
            raise RedisConnectionError()

        async def ping(self):
            raise RedisConnectionError()

    async with client_for(cache=Down()) as (client, app):
        assert (await client.post("/orders", json=payload)).status_code == 503
        assert (await client.get("/readyz")).status_code == 503
        assert (await client.get("/healthz")).status_code == 200
        assert "mock_broker_replayed_total" in (await client.get("/metrics")).text
