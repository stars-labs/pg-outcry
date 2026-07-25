-- generated from engine/pkg/models/trade_order/stop_order.sql — do not edit directly

CREATE TABLE stop_order(
    id                  BIGSERIAL PRIMARY KEY,
    pub_id              TEXT default uuid_generate_v4() UNIQUE NOT NULL,
    price               DECIMAL NOT NULL,           -- trigger price
    trade_order_id      BIGINT REFERENCES trade_order(id) UNIQUE NOT NULL
);

