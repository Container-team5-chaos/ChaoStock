import json
import time
import uuid
from datetime import datetime, timezone
from decimal import ROUND_DOWN, Decimal, localcontext

from .models import number


class PriceUnavailable(Exception):
    def __init__(self, reason):
        self.reason = reason


async def current_price(redis, market, stale_ms):
    raw = await redis.get(f"price:{market}")
    try:
        if not isinstance(raw, (str, bytes)) or len(raw) > 4096:
            raise ValueError("missing price")
        data = json.loads(raw)
        price = number(data["price"], scale=8, bound="1e16", positive=True)
        ts = data["ts"]
        if type(ts) is not int or ts <= 0 or ts > time.time() * 1000:
            raise ValueError("invalid timestamp")
    except (ValueError, TypeError, KeyError):
        raise PriceUnavailable("price_unavailable") from None
    if time.time() * 1000 - ts >= stale_ms:
        raise PriceUnavailable("stale_price")
    return price


def execution(payload, price):
    """One complete fill, no fees/partial fills. Ledger settlement belongs to D."""
    with localcontext() as ctx:
        ctx.prec = 64
        amount = (price * Decimal(payload["volume"])).quantize(
            Decimal("0.0001"), rounding=ROUND_DOWN
        )
    if amount >= Decimal("1e20"):
        return {**payload, "status": "rejected", "reason": "amount_out_of_range"}
    if payload.get("max_amount") is not None and amount > Decimal(
        payload["max_amount"]
    ):
        return {**payload, "status": "rejected", "reason": "price_limit_exceeded"}
    return {
        **payload,
        "status": "filled",
        "broker_order_id": "broker-" + uuid.uuid4().hex,
        "fill_price": f"{price:.8f}",
        "amount": f"{amount:.4f}",
        "filled_at": datetime.now(timezone.utc).isoformat(),
    }
