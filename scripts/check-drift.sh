#!/usr/bin/env bash
# Compare a deployed database against the migrations in this repo.
#
# Migration bookkeeping is NOT proof: anything applied by hand (a hotfix, a demo
# helper, an old overload that a later DROP missed) leaves no trace in
# schema_migrations. Two live backdoors were found this way — a demo_faucet()
# that minted balances and a legacy 2-arg request_deposit() that bypassed the
# chain-backed funding check.
#
# Usage:
#   scripts/check-drift.sh "postgresql://…"          # compare target vs a fresh local reset
#   BASELINE_URL=… scripts/check-drift.sh "…"        # compare against an existing baseline db
#
# Exits non-zero if the target has objects the baseline does not.
set -euo pipefail

TARGET="${1:-}"
[ -z "$TARGET" ] && { echo "usage: $0 <target-database-url>" >&2; exit 2; }
BASELINE="${BASELINE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"

objects() {   # dump a comparable inventory of the public schema
  psql "$1" -tA <<'SQL'
select 'table    '||tablename from pg_tables where schemaname='public'
union all select 'view     '||viewname from pg_views where schemaname='public'
union all select 'function '||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
union all select 'policy   '||tablename||'.'||policyname from pg_policies where schemaname='public'
union all select 'trigger  '||c.relname||'.'||t.tgname
  from pg_trigger t join pg_class c on c.oid=t.tgrelid
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and not t.tgisinternal
order by 1
SQL
}

# Time-rolled partitions (trade_p2026_05, …) are created by pg_cron relative to the
# clock, so a target and a fresh baseline legitimately differ. Filter them out, plus
# any object listed in scripts/drift-allow.txt (intentional, non-migration extras).
ALLOW="${ALLOW_FILE:-$(dirname "$0")/drift-allow.txt}"
filter() {
  grep -vE '_p[0-9]{4}_[0-9]{2}(\.|$)|_default(\.|$)' \
  | { [ -f "$ALLOW" ] && grep -vxFf <(grep -vE '^\s*(#|$)' "$ALLOW") || cat; }
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo "→ baseline: $BASELINE"
objects "$BASELINE" | filter | sort > "$tmp/baseline.txt"
echo "→ target:   ${TARGET%%\?*}"
objects "$TARGET"   | filter | sort > "$tmp/target.txt"

extra="$(comm -13 "$tmp/baseline.txt" "$tmp/target.txt" || true)"
missing="$(comm -23 "$tmp/baseline.txt" "$tmp/target.txt" || true)"

rc=0
if [ -n "$extra" ]; then
  echo
  echo "⚠ target has objects the repo does not (drift — audit these, they may be live backdoors):"
  printf '%s\n' "$extra" | sed 's/^/    /'
  rc=1
fi
if [ -n "$missing" ]; then
  echo
  echo "⚠ target is MISSING objects the repo defines (migrations not fully applied):"
  printf '%s\n' "$missing" | sed 's/^/    /'
  rc=1
fi
[ $rc -eq 0 ] && echo "✅ no drift: target matches the repo's migrations"
exit $rc
