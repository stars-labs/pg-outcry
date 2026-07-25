-- generated from engine/pkg/models/transfer/transfer_type.sql — do not edit directly

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE TYPE transfer_type AS ENUM (
    'DEPOSIT',
    'WITHDRAWAL',
    'TRANSFER',
    'INSTRUMENT_BUY',
    'INSTRUMENT_SELL',
    'CHARGE'
);

