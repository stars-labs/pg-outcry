**English** · [中文](./DEPLOY.zh-CN.md)

# Deployment

Two profiles from the **same migration set**:

| | **Demo — hosted Supabase** (supabase.com) | **Local high-performance** (self-host) |
|---|---|---|
| Where | Managed Supabase project | `supabase start` on your box / your own Postgres |
| Migrations | ✅ all (privileged ops self-skip) | ✅ all |
| Matching / settlement / wallet / auth / RLS / risk / back-office | ✅ | ✅ |
| Realtime (private feed + broadcast market data) | ✅ | ✅ |
| Partitioning + `pg_cron` roll | ✅ (enable `pg_cron` in dashboard) | ✅ |
| UNLOGGED hot book | ✅ (single primary; rebuild after failover) | ✅ |
| **Custom C extension** (`oc_fastmath`, native `banker_round`) | ❌ not allowed on hosted → PL/pgSQL | ✅ `ext/oc_fastmath/build.sh` |
| Per-role `statement_timeout`, `wal_compression`, etc. | set in dashboard | ✅ `scripts/perf-tune-local.sh` |

The migrations are written to **degrade gracefully**: operations needing
publication/role ownership or superuser (e.g. `ALTER PUBLICATION … SET
publish_via_partition_root`, `ALTER ROLE … SET statement_timeout`,
`CREATE EXTENSION pg_cron`, `cron.schedule`) are wrapped in best-effort blocks, so
`supabase db push` to a hosted project succeeds even where those are restricted.

---

## Demo: deploy to hosted Supabase

```bash
supabase login
supabase link --project-ref <your-project-ref>
supabase db push                 # applies every migration; privileged ops self-skip
```

If the browser login or `supabase login --token ...` flow hangs, avoid the
interactive login path and pass a dashboard access token through the environment
instead:

```bash
read -rs SUPABASE_ACCESS_TOKEN   # paste a Supabase dashboard access token
export SUPABASE_ACCESS_TOKEN

supabase link --project-ref <your-project-ref>
supabase db push --yes
```

Do not commit, paste, or leave access tokens in shell history. Revoke and rotate
any token that was exposed during deployment.

The public demo currently points at:

```bash
PROJECT_REF=axtziasfallmdgssbgsl
API=https://axtziasfallmdgssbgsl.supabase.co
```

The hosted demo has the latest migrations applied through
`99999_admin_rbac.sql`. The back-office is intentionally **test-open**: every
signed-in Supabase Auth user receives full admin permissions so reviewers can try
the console. Before production, tighten `admin_has_permission()` /
`current_admin_permissions()` back to `admin_operator_role`-based RBAC and disable
open signup if operator accounts must be pre-approved.

Then in the Supabase dashboard:
1. **Database → Extensions**: enable `pg_cron` (partition rolling + optional 1s
   market-data fallback). Optionally `pg_stat_statements`, `hypopg` for profiling.
2. **Database → Roles** (optional): set `statement_timeout` for `authenticated`
   (15s) / `service_role` (30s) — the migration skips these without ownership.
3. **Market data**: run the coalesced L2 ticker as an external client against your
   project (it only needs the service key):
   ```bash
   API=https://<ref>.supabase.co SERVICE=<service_role key> node examples/md-ticker.mjs
   ```
   (or register the pure-PG 1s fallback: `select cron.schedule('md','1 seconds','select broadcast_md()')`).

What you get on hosted: the full pure-PG CEX — PostgREST API, Auth+RLS, private
realtime feed, broadcast market data, wallet, risk, back-office. `banker_round`
runs as PL/pgSQL (bit-identical to the C version, just slower per call).

> Hosted notes: UNLOGGED `book_order`/`price_level` are not in PITR/replicas; after a
> failover run `select rebuild_book();` to rebuild the live book from open orders.

---

## Local high-performance: self-host

```bash
supabase start
supabase db reset                # apply all migrations

export ANON="$(supabase status -o json | jq -r .ANON_KEY)"
export SERVICE="$(supabase status -o json | jq -r .SERVICE_ROLE_KEY)"

# native C banker_round (drop-in, ~2.8x) + DB tunables
./scripts/perf-tune-local.sh

# market-data ticker (100ms coalesced L2 broadcasts)
SERVICE="$SERVICE" node examples/md-ticker.mjs &
```

`scripts/perf-tune-local.sh`:
- builds + loads `oc_fastmath` and swaps `banker_round` → native C (`ext/oc_fastmath/build.sh`);
- applies write-throughput tunables via `ALTER SYSTEM` as `supabase_admin`
  (`wal_compression=on`; optional `synchronous_commit=off` for max throughput at the
  cost of losing the last few committed txns on crash — opt in with `RISKY=1`).

Re-run `./scripts/perf-tune-local.sh` after any `supabase db reset` (a reset drops
the C `banker_round` and reverts to PL/pgSQL; the `.so` persists in PGDATA).

## What's identical across both
Same schema, same engine, same API surface, same tests (`scripts/smoke-*`). The only
runtime differences are native `banker_round` (local) and DB-level tunables (local /
dashboard). Functionally the hosted demo and local builds are the same pure-PG exchange.
