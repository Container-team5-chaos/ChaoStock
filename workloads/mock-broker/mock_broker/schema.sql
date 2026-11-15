CREATE TABLE IF NOT EXISTS mock_broker_orders (
    client_order_id TEXT PRIMARY KEY,
    payload JSONB NOT NULL,
    result JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (result->>'status' IN ('filled', 'rejected'))
);
