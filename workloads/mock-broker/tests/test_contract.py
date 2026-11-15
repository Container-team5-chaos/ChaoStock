"""Read the existing adapter/D clients without modifying or deploying them."""

import asyncio
import sys
from pathlib import Path

import httpx
import pytest

from conftest import client_for

WORKLOADS = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(WORKLOADS / "adapter"))
sys.path.insert(0, str(WORKLOADS / "order"))

from adapter.broker import Broker, RateLimiter, Retry  # noqa: E402
from adapter.models import OrderRequest  # noqa: E402
from app.adapter_client import validate_receipt  # noqa: E402


@pytest.mark.parametrize(
    "side,budget,status",
    [
        ("bid", "98000", "filled"),
        ("bid", "1", "rejected"),
        ("ask", None, "filled"),
    ],
)
async def test_existing_adapter_and_d_accept_result(payload, side, budget, status):
    payload.update(side=side, max_amount=budget)
    payload = OrderRequest(**payload).model_dump(exclude_none=True)
    async with client_for() as (client, app):
        broker = Broker(client, RateLimiter(10000))
        result = await broker.reconcile(payload)
        assert result.status == status
        again = await broker.reconcile(payload)
        assert again == result
        receipt = {
            **payload,
            "status": status,
            "result": result.model_dump(mode="json"),
        }
        assert validate_receipt(receipt, payload)["status"] == status
        assert len(app.state.db.rows) == 1


async def test_adapter_recovers_after_only_post_response_is_lost(payload):
    payload = OrderRequest(**payload).model_dump(exclude_none=True)
    async with client_for() as (client, app):
        post_calls = 0

        async def transport(request):
            nonlocal post_calls
            response = await client.request(
                request.method,
                request.url.path,
                content=request.content,
                headers=request.headers,
            )
            if request.method == "POST":
                post_calls += 1
                # Server has committed; only the client-facing response is lost.
                raise httpx.ReadTimeout("response lost", request=request)
            return response

        async with httpx.AsyncClient(
            transport=httpx.MockTransport(transport), base_url="http://broker"
        ) as upstream:
            broker = Broker(upstream, RateLimiter(10000))
            with pytest.raises(Retry):
                await broker.reconcile(payload)
            result = await broker.reconcile(payload)
            assert result.status == "filled" and post_calls == 1
            assert len(app.state.db.rows) == 1


async def test_concurrent_posts_share_result(payload):
    async with client_for() as (client, app):
        responses = await asyncio.gather(
            *(client.post("/orders", json=payload) for _ in range(20))
        )
        assert sum(r.status_code == 201 for r in responses) == 1
        assert all(r.json() == responses[0].json() for r in responses)
