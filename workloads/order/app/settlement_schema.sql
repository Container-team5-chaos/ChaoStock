-- 기존 주문은 보존하고, 이후 체결부터 실제 원장 반영 순서를 기록한다.
-- pending 접수 시에는 번호를 발급하지 않으므로 열에 DEFAULT를 두지 않는다.
ALTER TABLE orders ADD COLUMN IF NOT EXISTS settle_seq BIGINT;
CREATE SEQUENCE IF NOT EXISTS order_settle_seq;
ALTER SEQUENCE order_settle_seq OWNED BY orders.settle_seq;
