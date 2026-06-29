#!/usr/bin/env bash
# Retry wrapper for `supabase db reset` — the local-stack reset is occasionally flaky
# in CI runners (transient Docker/stack hiccup surfaces as a bare non-zero exit).
set -u
for i in 1 2 3; do
  if supabase db reset >/dev/null 2>&1; then exit 0; fi
  echo "(db reset attempt $i failed — retrying)" >&2
  sleep 5
done
echo "db reset failed after 3 attempts" >&2
exit 1
