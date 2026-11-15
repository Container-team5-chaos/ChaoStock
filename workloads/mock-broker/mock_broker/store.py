import hashlib
import json
from pathlib import Path

import asyncpg


class Conflict(Exception):
    pass


class Store:
    def __init__(self, pool):
        self.pool = pool

    @classmethod
    async def connect(cls, settings):
        return cls(
            await asyncpg.create_pool(
                settings.database_url,
                min_size=1,
                max_size=settings.db_pool_size,
                timeout=5,
                command_timeout=5,
            )
        )

    async def close(self):
        await self.pool.close()

    async def initialize(self):
        async with self.pool.acquire() as conn, conn.transaction():
            await conn.execute("SELECT pg_advisory_xact_lock(739014202)")
            await conn.execute(
                Path(__file__).with_name("schema.sql").read_text("utf-8")
            )

    async def ready(self):
        await self.pool.fetchval(
            "SELECT count(*) FROM (SELECT 1 FROM mock_broker_orders LIMIT 1) s"
        )

    async def get(self, key):
        raw = await self.pool.fetchval(
            "SELECT result FROM mock_broker_orders WHERE client_order_id = $1", key
        )
        return json.loads(raw) if raw is not None else None

    async def execute(self, payload, make_result):
        # A stable DB lock serializes the same key across requests and processes.
        # Hash collisions only serialize unrelated keys; PK remains the identity.
        key = payload["client_order_id"]
        lock = int.from_bytes(
            hashlib.sha256(("mock-broker:" + key).encode()).digest()[:8],
            "big",
            signed=True,
        )
        async with self.pool.acquire() as conn, conn.transaction():
            await conn.execute("SELECT pg_advisory_xact_lock($1::bigint)", lock)
            row = await conn.fetchrow(
                "SELECT payload, result FROM mock_broker_orders WHERE client_order_id = $1",
                key,
            )
            if row is not None:
                if json.loads(row["payload"]) != payload:
                    raise Conflict
                return json.loads(row["result"]), True
            # Redis is bounded by its own timeout. No external trade is made here.
            result = await make_result()
            await conn.execute(
                "INSERT INTO mock_broker_orders(client_order_id,payload,result) VALUES($1,$2::jsonb,$3::jsonb)",
                key,
                json.dumps(payload),
                json.dumps(result),
            )
        # Commit before sending (or artificially delaying) the response.
        return result, False
