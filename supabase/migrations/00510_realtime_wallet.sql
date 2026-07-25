-- Stage 6: extend the authenticated private feed with wallet status.
-- wallet_request is RLS-scoped (own_wallet_requests), so publishing it to Realtime
-- lets a user receive live updates on THEIR OWN requests (e.g. PENDING -> APPROVED)
-- while Postgres Changes enforces the RLS per subscriber. Combined with the
-- already-published trade_order, an authenticated client gets a complete private
-- stream: order lifecycle + fills + wallet status.

alter publication supabase_realtime add table wallet_request;
alter table wallet_request replica identity full;
