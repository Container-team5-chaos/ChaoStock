import asyncio
import json
import time
from contextlib import asynccontextmanager

import httpx
import pytest
from asgi_lifespan import LifespanManager

from mock_broker.config import Settings
from mock_broker.main import create_app
from mock_broker.store import Conflict


class MemoryStore:
    def __init__(self):
        self.rows = {}
        self.lock = asyncio.Lock()

    async def ready(self):
        pass

    async def get(self, key):
        row = self.rows.get(key)
        return row[1] if row else None

    async def execute(self, payload, make_result):
        async with self.lock:
            key = payload["client_order_id"]
            if key in self.rows:
                original, result = self.rows[key]
                if original != payload:
                    raise Conflict
                return result, True
            result = await make_result()
            self.rows[key] = (payload, result)
            return result, False


class Cache:
    def __init__(self):
        self.value = json.dumps({"price": "98000000", "ts": int(time.time() * 1000)})
        self.calls = 0

    async def get(self, key):
        assert key == "price:KRW-BTC"
        self.calls += 1
        return self.value

    async def ping(self):
        return True


@pytest.fixture
def payload():
    return {
        "client_order_id": "test-1",
        "user_id": "user-0001",
        "market": "KRW-BTC",
        "side": "bid",
        "volume": "0.001",
        "max_amount": "98000",
    }


@asynccontextmanager
async def client_for(*, store=None, cache=None, **settings):
    app = create_app(
        Settings("unused", **settings),
        store=store or MemoryStore(),
        redis_client=cache or Cache(),
    )
    async with (
        LifespanManager(app),
        httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://broker"
        ) as client,
    ):
        yield client, app
