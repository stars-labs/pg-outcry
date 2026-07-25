-- generated from engine/pkg/models/instrument_account/instrument_account.sql — do not edit directly

-- Instrument account belonging to application entity
CREATE TABLE instrument_account (
    id                      BIGSERIAL PRIMARY KEY,
    pub_id                  TEXT default uuid_generate_v4() UNIQUE NOT NULL,
    app_entity_id           BIGINT REFERENCES app_entity(id) NOT NULL,
    updated_at              TIMESTAMPTZ default current_timestamp NOT NULL,
    created_at              TIMESTAMPTZ default current_timestamp NOT NULL
);

CREATE INDEX idx_instrument_account_app_entity_id ON instrument_account(app_entity_id);

