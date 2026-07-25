-- generated from engine/pkg/models/currency/currency.sql — do not edit directly

CREATE TABLE currency (
   name                               TEXT PRIMARY KEY,
   precision                          INT default 2 NOT NULL
);

