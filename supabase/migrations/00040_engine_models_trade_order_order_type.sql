-- generated from engine/pkg/models/trade_order/order_type.sql — do not edit directly

CREATE TYPE order_type AS ENUM (
    'LIMIT',
    'MARKET',
    'STOPLOSS',
    'STOPLIMIT'
);

