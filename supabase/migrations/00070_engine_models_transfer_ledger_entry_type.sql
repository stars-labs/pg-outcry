-- generated from engine/pkg/models/transfer/ledger_entry_type.sql — do not edit directly

DO $$ BEGIN
    CREATE TYPE ledger_entry_type AS ENUM ('DEBIT', 'CREDIT');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

