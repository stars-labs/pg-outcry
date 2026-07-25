-- Performance: reduce WAL pressure from realtime publication.
--
-- 9001/9101/9310 set REPLICA IDENTITY FULL on published tables, which writes the
-- ENTIRE old row to WAL on every UPDATE/DELETE. Postgres Changes only needs the
-- NEW tuple (always in WAL) for INSERT/UPDATE, so for tables with a primary key
-- we can use REPLICA IDENTITY DEFAULT (PK only) and cut WAL volume sharply.
--
-- Exception: price_level keeps FULL because a client rendering the L2 book needs
-- the price/side on a DELETE event (volume → 0) to remove the right level; with
-- DEFAULT a DELETE would carry only the row id.

alter table trade          replica identity default;  -- insert-only tape: biggest win
alter table trade_order    replica identity default;  -- consumers read NEW (status/open_amount)
alter table book_order     replica identity default;  -- not the client-facing L2
alter table wallet_request replica identity default;  -- consumers read NEW (status)
-- price_level stays FULL (L2 delete needs old price/side)
