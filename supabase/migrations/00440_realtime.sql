-- Stage 1: drive the client feed with supabase-realtime instead of a Go relay.
--
-- The engine has no pg_notify today; here we publish the relevant tables to the
-- `supabase_realtime` publication so Realtime's Postgres Changes broadcasts every
-- new trade / order-book row over websockets. RLS stays off for this stage, so
-- the changes are public and easy to observe.

alter publication supabase_realtime add table trade;
alter publication supabase_realtime add table trade_order;
alter publication supabase_realtime add table book_order;

-- emit full row images on update/delete too (handy when watching the book)
alter table trade replica identity full;
alter table trade_order replica identity full;
alter table book_order replica identity full;
