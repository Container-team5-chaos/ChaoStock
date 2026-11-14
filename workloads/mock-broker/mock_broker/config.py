import math
import os
from dataclasses import dataclass
from urllib.parse import quote


@dataclass(frozen=True)
class Settings:
    database_url: str
    redis_url: str = "redis://redis:6379/0"
    stale_ms: int = 5000
    db_pool_size: int = 5
    response_delay: float = 0
    rate_limit_rps: float = 0

    def __post_init__(self):
        for name in ("stale_ms", "db_pool_size", "response_delay", "rate_limit_rps"):
            value = getattr(self, name)
            if not math.isfinite(value) or value < 0:
                raise ValueError(f"{name} must be finite and nonnegative")
        if not self.stale_ms or not self.db_pool_size:
            raise ValueError("stale_ms and db_pool_size must be positive")

    @classmethod
    def from_env(cls):
        dsn = os.getenv("DATABASE_URL")
        if not dsn:
            user, password, database = (
                quote(os.environ[name], safe="")
                for name in ("POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB")
            )
            dsn = (
                f"postgresql://{user}:{password}@{os.environ['PGHOST']}:"
                f"{os.getenv('PGPORT', '5432')}/{database}"
            )
        return cls(
            database_url=dsn,
            redis_url=os.getenv("REDIS_URL", cls.redis_url),
            stale_ms=int(os.getenv("STALE_MS", "5000")),
            db_pool_size=int(os.getenv("DB_POOL_SIZE", "5")),
            response_delay=float(os.getenv("RESPONSE_DELAY_SECONDS", "0")),
            rate_limit_rps=float(os.getenv("RATE_LIMIT_RPS", "0")),
        )
