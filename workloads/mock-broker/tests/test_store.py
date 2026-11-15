import asyncio
import os
import uuid
from decimal import Decimal

import asyncpg
import pytest
import pytest_asyncio

from conftest import client_for
from mock_broker.models import Order
from mock_broker.pricing import execution
from mock_broker.store import Conflict, Store


@pytest_asyncio.fixture
async def db_store():
    dsn = os.getenv("MOCK_BROKER_TEST_DATABASE_URL")
    if not dsn:
        pytest.skip("set MOCK_BROKER_TEST_DATABASE_URL for isolated PostgreSQL tests")
    schema = "mock_broker_test_" + uuid.uuid4().hex
    conn = await asyncpg.connect(dsn)
    pool = None
    try:
        await conn.execute(f'CREATE SCHEMA "{schema}"')
        pool = await asyncpg.create_pool(
            dsn, min_size=1, max_size=5, server_settings={"search_path": schema}
        )
        store = Store(pool)
        await store.initialize()
        yield store
    finally:
        if pool is not None:
            await pool.close()
        await conn.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
        await conn.close()


async def test_concurrent_orders_restart_and_conflict(db_store, payload):
    payload = Order(**payload).model_dump(exclude_none=True)
    calls = 0

    async def fill():
        nonlocal calls
        calls += 1
        await asyncio.sleep(0.01)
        return execution(payload, Decimal("98000000"))

    results = await asyncio.gather(
        *(Store(db_store.pool).execute(payload, fill) for _ in range(20))
    )
    assert calls == 1 and sum(not replay for _, replay in results) == 1
    assert all(result == results[0][0] for result, _ in results)
    await db_store.initialize()
    assert await Store(db_store.pool).get("test-1") == results[0][0]
    with pytest.raises(Conflict):
        await db_store.execute({**payload, "user_id": "other"}, fill)


async def test_failure_rolls_back_and_key_can_retry(db_store, payload):
    async def fail():
        raise TimeoutError()

    with pytest.raises(TimeoutError):
        await db_store.execute(payload, fail)
    assert await db_store.get("test-1") is None
    async with client_for(store=db_store) as (client, app):
        assert (await client.post("/orders", json=payload)).status_code == 201


async def test_commit_survives_client_timeout(db_store, payload):
    async with client_for(store=db_store, response_delay=0.2) as (client, app):
        with pytest.raises(TimeoutError):
            await asyncio.wait_for(client.post("/orders", json=payload), timeout=0.1)
    # Recreate the application/store to prove this is persisted, not process memory.
    async with client_for(store=Store(db_store.pool)) as (client, app):
        result = (await client.get("/orders/test-1")).json()
        assert result["status"] == "filled"
        assert (await client.post("/orders", json=payload)).json() == result
