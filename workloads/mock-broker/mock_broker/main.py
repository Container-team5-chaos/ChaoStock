import asyncio
import math
import time
from contextlib import asynccontextmanager

import asyncpg
import redis.asyncio as redis
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    generate_latest,
)
from redis.exceptions import RedisError

from .config import Settings
from .models import Order
from .pricing import PriceUnavailable, current_price, execution
from .store import Conflict, Store

DB_ERRORS = (asyncpg.PostgresError, OSError, TimeoutError)


def create_app(settings=None, *, store=None, redis_client=None):
    registry = CollectorRegistry()
    completed = Counter(
        "mock_broker_orders_total",
        "Durably decided orders",
        ["status"],
        registry=registry,
    )
    replayed = Counter(
        "mock_broker_replayed_total", "Replayed POST results", registry=registry
    )
    limited = Counter(
        "mock_broker_rate_limited_total", "Rate limited requests", registry=registry
    )

    @asynccontextmanager
    async def lifespan(app):
        cfg = settings or Settings.from_env()
        db = store if store is not None else await Store.connect(cfg)
        cache = (
            redis_client
            if redis_client is not None
            else redis.from_url(
                cfg.redis_url,
                decode_responses=True,
                socket_timeout=2,
                socket_connect_timeout=2,
                max_connections=10,
            )
        )
        app.state.stopping = False
        app.state.next_request = 0
        app.state.cfg, app.state.db, app.state.cache = cfg, db, cache
        try:
            await db.ready()
            yield
        finally:
            app.state.stopping = True
            if redis_client is None:
                await cache.aclose()
            if store is None:
                await db.close()

    app = FastAPI(title="ChaoStock Mock Broker", lifespan=lifespan)
    app.state.stopping = False

    def error(reason, code, key=None, headers=None):
        return JSONResponse(
            {"status": "rejected", "reason": reason, "client_order_id": key},
            status_code=code,
            headers=headers,
        )

    def gate(key):
        if app.state.stopping:
            return error("not_ready", 503, key)
        rps = app.state.cfg.rate_limit_rps
        if rps:
            now = time.monotonic()
            remaining = app.state.next_request - now
            if remaining > 0:
                limited.inc()
                return error(
                    "rate_limited",
                    429,
                    key,
                    {"Retry-After": str(max(1, math.ceil(remaining)))},
                )
            # No await between checking and reserving this process's slot.
            app.state.next_request = now + 1 / rps
        return None

    async def respond(body, code=200):
        await asyncio.sleep(app.state.cfg.response_delay)
        return JSONResponse(body, status_code=code)

    @app.exception_handler(RequestValidationError)
    async def invalid(request, exc):
        return error("invalid_request", 400)

    @app.post("/orders")
    async def submit(order: Order, request: Request):
        key = order.client_order_id
        if request.headers.get("Idempotency-Key", key) != key:
            return error("invalid_request", 400, key)
        denied = gate(key)
        if denied is not None:
            return denied
        payload = order.model_dump(exclude_none=True)

        async def make_result():
            price = await current_price(
                app.state.cache, order.market, app.state.cfg.stale_ms
            )
            return execution(payload, price)

        try:
            result, replay = await app.state.db.execute(payload, make_result)
        except Conflict:
            return error("idempotency_conflict", 409, key)
        except PriceUnavailable as exc:
            return error(exc.reason, 503, key)
        except (*DB_ERRORS, RedisError):
            return error("not_ready", 503, key)
        if replay:
            replayed.inc()
        else:
            completed.labels(result["status"]).inc()
        return await respond(
            result, 200 if replay or result["status"] == "rejected" else 201
        )

    @app.get("/orders/{client_order_id}")
    async def lookup(client_order_id: str):
        denied = gate(client_order_id)
        if denied is not None:
            return denied
        try:
            result = await app.state.db.get(client_order_id)
        except DB_ERRORS:
            return error("not_ready", 503, client_order_id)
        if result is None:
            await asyncio.sleep(app.state.cfg.response_delay)
            return error("order_not_found", 404, client_order_id)
        return await respond(result)

    @app.get("/healthz")
    async def health():
        return {"ok": True}

    @app.get("/readyz")
    async def ready():
        if app.state.stopping:
            return error("not_ready", 503)
        try:
            await app.state.db.ready()
            await app.state.cache.ping()
        except (*DB_ERRORS, RedisError):
            return error("not_ready", 503)
        return {"ready": True}

    @app.get("/metrics")
    async def metrics():
        return Response(
            generate_latest(registry), headers={"Content-Type": CONTENT_TYPE_LATEST}
        )

    return app


app = create_app()
