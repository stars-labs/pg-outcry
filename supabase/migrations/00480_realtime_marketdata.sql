-- Stage 2 (part 2): public market-data push.
-- price_level is the aggregated L2 book; streaming it gives clients live
-- order-book updates without replaying every raw book_order row.

alter publication supabase_realtime add table price_level;
alter table price_level replica identity full;
