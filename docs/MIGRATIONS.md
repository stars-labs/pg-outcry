**English** · [中文](./MIGRATIONS.zh-CN.md)

# Migration numbering

All migrations use a **5-digit, fixed-width, step-10 numeric prefix**:
`00010_`, `00020_`, … `00910_`.

```
supabase/migrations/00010_engine_models_transfer_transfer_type.sql
supabase/migrations/00020_engine_models_trade_order_order_fill.sql
...
supabase/migrations/00910_chain_backed_funding_reconcile.sql
```

## Why fixed-width

The Supabase CLI applies migrations in **lexical filename order**, and takes the
digits before the first `_` as the migration **version** (the `schema_migrations`
primary key). Two consequences bit us repeatedly under the old mixed-width scheme:

- **Lexical ≠ numeric when widths differ.** `'9' (0x39) < '_' (0x5F)`, so
  `99999_admin_rbac.sql` sorted *before* `9999_stablecoin_tokens.sql`, and
  `100000_…` sorted near the *front* (`'1' < '9'`) rather than the end.
- **Versions must be unique.** `9999_a.sql` and `9999_b.sql` both parse to version
  `9999` and collide on the `schema_migrations` primary key, breaking
  `db reset` / `db push`.
- **Prefixes must be numeric.** A letter prefix (`A001_…`) is silently **skipped**
  by the CLI — the migration never runs, with no error.

With every prefix the same width, lexical order *is* numeric order, and the
ordering surprises disappear.

## Adding a migration

- **Append**: next multiple of 10 after the current last file.
- **Insert between two migrations**: use a spare number in the gap (e.g. `00565_`
  between `00560_` and `00570_`). The step-10 spacing exists for exactly this.
- Never reuse a number, and never change the prefix of a migration that has
  already been applied to a deployed database (see below).

## Renumbering an already-deployed database

Renaming a migration file changes its **version**, so the CLI would treat it as
new and try to re-apply it. Several migrations are destructive on replay (e.g.
`00580_cold_partitioning.sql` does `drop table if exists trade cascade`), so a
blind re-apply **loses data**.

The safe procedure is to rewrite the recorded versions instead of re-running
anything:

```sql
-- inside a transaction, map every old version string to the new one
update supabase_migrations.schema_migrations set version = '00010' where version = '0001';
...
```

Local/CI databases are disposable — just `supabase db reset`.
