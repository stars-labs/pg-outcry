**English** · [中文](./RLS.zh-CN.md)

# Row-Level Security model & conventions

How pg-outcry secures table access, why RLS is **declarative** in migrations, and the CI guard
that stops the recurring "auto-RLS" footgun. [← docs](./README.md) · [← Development](./DEVELOPMENT.md)

## The model: deny-by-default, access via the API surface

Users never touch base tables directly. Everything a client does goes through:

- **`SECURITY DEFINER` RPCs** — `place_order`, `request_withdrawal_to`, `stake`, `my_deposit_address`,
  … They run as the owner, do their own authorization (`current_app_entity_id()`), and bypass RLS.
- **A small set of views** granted to `anon` / `authenticated`.

`9900_lockdown.sql` revokes `EXECUTE` on every function from `anon`/`authenticated` and re-grants only
the whitelisted RPCs. Tables follow the same spirit: **RLS on, deny-by-default**, opened only where a
client genuinely needs to read.

## Three table classes

| Class | Examples | Policy |
|---|---|---|
| **Public reference / params** | `instrument`, `currency`, `fee`, `price_level`, `stake_pool`, `perp_market`, `margin_config`, `stake_config`, `referral_config`, `instrument_risk`, `withdrawal_limit` | `SELECT … USING (true)` to `anon, authenticated` — non-sensitive market/exchange parameters |
| **Per-user data** | `currency_account`, `trade_order`, `wallet_request`, `watched_address`, `withdrawal_address`, `user_chain_wallet`, `stake_position`, `perp_position`, `margin_loan`, `api_key`, `chain_deposit`, `perp_event`, `margin_liquidation` | `SELECT … USING (app_entity_id = current_app_entity_id())` (or an equivalent owner check, e.g. memo `'oc' || current_app_entity_id()` for `chain_deposit`) |
| **Financial / ledger / engine-internal** | `transfer`, `*_ledger_entry_*`, `book_order`, `admin_audit_log`, `chain_cursor`, `chain_balance_cursor`, `trade` partitions, `stop_order`, `instrument_account_transfer` | **RLS on, no policy = deny-by-default.** Correct and intentional — clients reach these only via `SECURITY DEFINER` RPCs/views. Do **not** add a policy. |

## The crux: `security_invoker` vs `SECURITY DEFINER` views

- A **`SECURITY DEFINER`** view (the Postgres default) runs as its owner and **bypasses RLS** on its base
  tables. `margin_terms`, `perp_markets`, `stake_pools`, `referral_summary`, `reconciliation_report` are
  definer views — they read config/internal tables without needing policies.
- A **`security_invoker = on`** view runs as the **caller**, so RLS on its base tables **applies**. All the
  per-user views are invoker views: `cash_balances`, `my_stakes`, `my_perp`, `my_margin`,
  `my_chain_deposits`, `my_deposit_addresses`, `withdrawal_addresses`, `open_orders`, `order_book_l2`,
  `trade_history`, `instrument_balances`, `api_keys`.

> **An invoker view that reads a table with RLS enabled but _zero policies_ silently returns nothing.**

## The footgun: Supabase auto-enables RLS

Supabase's security advisor enables RLS on public tables **out-of-band** (not via our migrations). If that
hits a table an invoker view reads and we never wrote a policy, the feature breaks on hosted while CI
(a fresh local DB, where RLS was never auto-enabled) stays green. We hit this on `stake_pool`,
`perp_market`, and `chain_deposit`.

**Rule: make RLS declarative.** In the migration that creates a table, both `ENABLE ROW LEVEL SECURITY`
**and** add its policy (or deliberately leave it deny-by-default for internal tables). Then a fresh DB
== hosted, and Supabase's auto-toggle changes nothing.

```sql
alter table stake_pool enable row level security;          -- match what hosted will do anyway
create policy read_stake_pool on stake_pool
  for select to anon, authenticated using (true);          -- … and the intended policy
```

## The CI guard

`scripts/check-rls-policies.sh` (run in `ci.yml` right after migrations apply) walks every
`security_invoker` view granted to `anon`/`authenticated`, resolves its base tables via
`pg_depend`/`pg_rewrite`, and **fails** if any base table is RLS-enabled-with-no-policy — printing the
offending `view -> table` pairs. It ignores the deny-by-default internal tables (no invoker view reads
them), so it never forces a wrong policy. Run it anywhere:

```bash
PGURL=postgresql://user:pass@host:5432/db bash scripts/check-rls-policies.sh
```

## Checklist when adding a table or view

1. Creating a table read by clients? `ENABLE ROW LEVEL SECURITY` + add the right policy in the same
   migration (public-read or own-row). Internal/ledger table? Enable RLS, no policy.
2. Need a per-user view? Make it `security_invoker = on` and ensure every base table has an own-row (or
   public-read) policy. Need to expose aggregated/internal data safely? Use a `SECURITY DEFINER` view.
3. Numbered `> 9900` so `9900_lockdown` has already run before your grants.
4. `bash scripts/check-rls-policies.sh` locally — green before pushing.

## Self-host reuses all of it

Everything here is plain SQL migrations applied by `supabase db reset` (or `supabase db push`), so a
self-hosted Postgres gets the identical RLS posture — no hosted-only steps. The CI guard runs against any
`PGURL`. The one hosted-specific behavior (Supabase auto-enabling RLS) is precisely what the declarative
approach neutralizes, so local, CI, and hosted stay in lockstep. See [DEPLOY.md](./DEPLOY.md).
