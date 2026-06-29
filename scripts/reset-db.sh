#!/usr/bin/env bash
# Retry wrapper for `supabase db reset` — the local-stack reset is occasionally flaky
# in CI runners (transient Docker/stack hiccup surfaces as a bare non-zero exit). The
# CI runs ~8 resets, so even a low per-reset failure rate adds up; retry generously.
set -u
for i in 1 2 3 4 5; do
  if supabase db reset >/dev/null 2>&1; then exit 0; fi
  echo "(db reset attempt $i failed — retrying)" >&2
  sleep $((i * 5))
done
echo "db reset failed after 5 attempts" >&2
exit 1
