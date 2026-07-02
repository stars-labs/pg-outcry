# Migration numbering

The original scheme is 4-digit numeric prefixes (`0001_…` → `9999_…`). That space
is **exhausted**: `9999_stablecoin_tokens.sql` holds the last clean slot.

Rules learned the hard way:

- **Numeric prefixes only.** The Supabase CLI treats the digits before the first
  `_` as the migration version; files with non-numeric prefixes (e.g. `A001_…`)
  are skipped. Letter prefixes are NOT a valid escape hatch.
- **Versions must be unique.** Two files sharing a digit prefix (`9999_a.sql`,
  `9999_b.sql`, or `9999_x` vs a would-be `9999z_y`) collide on the
  `schema_migrations` primary key and break `db reset`/`db push`.
- **Apply order is lexical by filename**, and `'9' < '_'`, so 5-digit `9999N_…`
  sorts *between* `9998_…` and `9999_…` (and `99991_…` < `99999_…`).

## Current convention

New migrations use **5-digit `9999N_` prefixes** (`99991`–`99998`; `99999` is
already taken by admin RBAC). They apply after `9998_` but **before**
`99999_admin_rbac` and `9999_stablecoin_tokens`, so:

- They may depend on anything up to `9998_…` at DDL time.
- They must NOT reference objects created by `99999_…`/`9999_…` at DDL time
  (runtime references from function bodies are fine — resolved at call time).

When `99991`–`99998` run out, the next step is a full switch to 14-digit
timestamp prefixes — which requires renumbering awareness because timestamps
(`2026…`) sort lexically before `3000_…`; plan that as a one-time migration-set
reorganization, not an incremental add.
