-- generated from engine/pkg/services/order_book/get_market_orders.sql — do not edit directly


-- UNUSED
CREATE OR REPLACE FUNCTION
    get_market_orders(
        instrument_id_param BIGINT,
        side_param order_side
    )
    RETURNS setof book_order
    LANGUAGE 'plpgsql'
AS $$
BEGIN
     IF side_param = 'SELL' THEN
        RETURN QUERY SELECT * FROM book_order
        WHERE instrument_id = instrument_id_param
            AND side = side_param
            AND order_type = 'MARKET'::order_type
        -- order first by price then by date created
        ORDER BY created_at;
    ELSE
        RETURN QUERY SELECT * FROM book_order
        WHERE instrument_id = instrument_id_param
            AND side = side_param
            AND order_type = 'MARKET'::order_type
        -- order first by price then by date created
        ORDER BY created_at;
    END IF;
END;
$$;


