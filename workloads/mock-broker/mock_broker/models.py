from decimal import Decimal, InvalidOperation
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


def number(value, *, scale, bound, positive=False):
    if not isinstance(value, str) or not 1 <= len(value) <= 64:
        raise ValueError("decimal must be a string")
    try:
        result = Decimal(value)
    except InvalidOperation as exc:
        raise ValueError("invalid decimal") from exc
    if (
        not result.is_finite()
        or result < 0
        or (positive and result == 0)
        or result >= Decimal(bound)
        or result.as_tuple().exponent < -scale
    ):
        raise ValueError("decimal out of range")
    return result


class Order(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    client_order_id: str = Field(pattern=r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
    user_id: str = Field(min_length=1, max_length=64)
    market: Literal["KRW-BTC"]
    side: Literal["bid", "ask"]
    volume: str
    max_amount: str | None = None

    @field_validator("volume")
    @classmethod
    def volume_valid(cls, value):
        return f"{number(value, scale=8, bound='1e22', positive=True):.8f}"

    @field_validator("max_amount")
    @classmethod
    def budget_valid(cls, value):
        if value is None:
            return None
        return f"{number(value, scale=4, bound='1e20'):.4f}"
