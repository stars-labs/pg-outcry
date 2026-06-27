-- OPT-IN: in-database deposit pollers for Ethereum Sepolia, Tron Nile, and Solana
-- testnet. These poll a live RPC/explorer over HTTP from inside Postgres and call
-- credit_chain_deposit() (migration 9920) for confirmed deposits to watched
-- addresses. NOT a migration and NOT run in CI/hosted — they need a real rpc_url,
-- outbound network, and pg_cron. Apply manually on a self-host once you've set the
-- RPC URLs and asset mappings:
--
--   psql "$DB_URL" -f supabase/chain/pollers.sql
--   -- then configure (examples):
--   update chain set rpc_url='https://ethereum-sepolia-rpc.publicnode.com', enabled=true where name='ethereum-sepolia';
--   update chain set rpc_url='https://nile.trongrid.io',                    enabled=true where name='tron-nile';
--   update chain set rpc_url='https://api.testnet.solana.com',              enabled=true where name='solana-testnet';
--   -- map an on-chain asset to an exchange currency (demo maps testnet assets to EUR):
--   insert into chain_asset(chain,token,currency,decimals) values
--     ('ethereum-sepolia', lower('0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238'), 'EUR', 6),  -- e.g. test USDC
--     ('tron-nile',        'native', 'EUR', 6),
--     ('solana-testnet',   'native', 'EUR', 9);
--
-- Uses the synchronous `http` extension (simpler than pg_net's async two-phase for
-- a periodic poller). Withdrawals are NOT here — signing needs an external signer.

create extension if not exists http with schema extensions;

-- ── Ethereum (Sepolia) — ERC-20 Transfer logs via eth_getLogs ───────────────────
-- Transfer(address,address,uint256) topic0:
--   0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef
create or replace function poll_evm(chain_param text) returns int
  language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  cfg chain%rowtype; a chain_asset%rowtype; latest bigint; fromb bigint; nb int := 0;
  body jsonb; resp jsonb; lg jsonb; topics jsonb; addr text; amt numeric; conf bigint;
begin
  select * into cfg from chain where name = chain_param and enabled and kind = 'evm';
  if not found then return 0; end if;

  -- latest block height
  resp := (extensions.http_post(cfg.rpc_url,
            '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}', 'application/json')).content::jsonb;
  latest := ('x' || lpad(substr(resp->>'result', 3), 16, '0'))::bit(64)::bigint;
  select last_scanned::bigint into fromb from chain_cursor where chain = chain_param;
  fromb := coalesce(fromb, latest - 5000) + 1;

  for a in select * from chain_asset where chain = chain_param and token <> 'native' loop
    body := jsonb_build_object('jsonrpc','2.0','id',1,'method','eth_getLogs','params',
      jsonb_build_array(jsonb_build_object(
        'fromBlock', to_hex(fromb), 'toBlock', to_hex(latest), 'address', a.token,
        'topics', jsonb_build_array('0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'))));
    resp := (extensions.http_post(cfg.rpc_url, body::text, 'application/json')).content::jsonb;
    for lg in select * from jsonb_array_elements(resp->'result') loop
      topics := lg->'topics';
      addr := '0x' || right(topics->>2, 40);                       -- indexed `to`
      if exists (select 1 from watched_address w where w.chain = chain_param and lower(w.address) = lower(addr)) then
        amt  := ('x' || lpad(substr(lg->>'data', 3), 16, '0'))::bit(64)::bigint / power(10, a.decimals);
        conf := latest - ('x' || lpad(substr(lg->>'blockNumber', 3), 16, '0'))::bit(64)::bigint;
        perform credit_chain_deposit(chain_param, lg->>'transactionHash',
                  ('x'||lpad(substr(lg->>'logIndex',3),16,'0'))::bit(64)::bigint::int,
                  addr, a.currency, amt, conf::int);
        nb := nb + 1;
      end if;
    end loop;
  end loop;

  insert into chain_cursor(chain, last_scanned) values (chain_param, latest)
    on conflict (chain) do update set last_scanned = excluded.last_scanned;
  return nb;
end $$;

-- ── Tron (Nile) — TRC-20 transfers via TronGrid REST per watched address ────────
create or replace function poll_tron(chain_param text) returns int
  language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare cfg chain%rowtype; w record; resp jsonb; tx jsonb; cur text; dec int; nb int := 0; amt numeric;
begin
  select * into cfg from chain where name = chain_param and enabled and kind = 'tron';
  if not found then return 0; end if;
  for w in select address from watched_address where chain = chain_param loop
    resp := (extensions.http_get(cfg.rpc_url || '/v1/accounts/' || w.address ||
              '/transactions/trc20?only_confirmed=true&limit=50')).content::jsonb;
    for tx in select * from jsonb_array_elements(resp->'data') loop
      select currency, decimals into cur, dec from chain_asset
        where chain = chain_param and token = lower(tx->'token_info'->>'address');
      if cur is not null and lower(tx->>'to') = lower(w.address) then
        amt := (tx->>'value')::numeric / power(10, dec);
        perform credit_chain_deposit(chain_param, tx->>'transaction_id', 0, w.address, cur, amt, cfg.confirmations);
        nb := nb + 1;
      end if;
    end loop;
  end loop;
  return nb;
end $$;

-- ── Solana (testnet) — native SOL via getSignaturesForAddress + getTransaction ───
create or replace function poll_solana(chain_param text) returns int
  language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare cfg chain%rowtype; w record; a chain_asset%rowtype; sigs jsonb; s jsonb; tx jsonb; nb int := 0; amt numeric; idx int;
begin
  select * into cfg from chain where name = chain_param and enabled and kind = 'solana';
  if not found then return 0; end if;
  select * into a from chain_asset where chain = chain_param and token = 'native';
  if not found then return 0; end if;
  for w in select address from watched_address where chain = chain_param loop
    sigs := (extensions.http_post(cfg.rpc_url,
      jsonb_build_object('jsonrpc','2.0','id',1,'method','getSignaturesForAddress',
        'params', jsonb_build_array(w.address, jsonb_build_object('limit',25)))::text,
      'application/json')).content::jsonb -> 'result';
    for s in select * from jsonb_array_elements(sigs) loop
      if (s->>'confirmationStatus') = 'finalized' and s->'err' is null then
        tx := (extensions.http_post(cfg.rpc_url,
          jsonb_build_object('jsonrpc','2.0','id',1,'method','getTransaction',
            'params', jsonb_build_array(s->>'signature', jsonb_build_object('encoding','jsonParsed','maxSupportedTransactionVersion',0)))::text,
          'application/json')).content::jsonb -> 'result';
        -- credit the net balance increase of the watched account (lamports → SOL)
        idx := (select ordinality-1 from jsonb_array_elements_text(tx->'transaction'->'message'->'accountKeys') with ordinality where value = w.address limit 1);
        if idx is not null then
          amt := ((tx->'meta'->'postBalances'->>idx)::numeric - (tx->'meta'->'preBalances'->>idx)::numeric) / power(10, a.decimals);
          if amt > 0 then
            perform credit_chain_deposit(chain_param, s->>'signature', 0, w.address, a.currency, amt, cfg.confirmations);
            nb := nb + 1;
          end if;
        end if;
      end if;
    end loop;
  end loop;
  return nb;
end $$;

-- Dispatch + schedule. One cron entry polls every enabled chain every 20s.
create or replace function poll_all_chains() returns void
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare c chain%rowtype;
begin
  for c in select * from chain where enabled loop
    begin
      perform case c.kind when 'evm' then poll_evm(c.name)
                          when 'tron' then poll_tron(c.name)
                          when 'solana' then poll_solana(c.name) end;
    exception when others then
      raise warning 'poll % failed: %', c.name, sqlerrm;   -- one bad chain never blocks the others
    end;
  end loop;
end $$;

-- register the job (pg_cron 1.6 supports sub-minute interval syntax)
select cron.schedule('poll-chain-deposits', '20 seconds', 'select poll_all_chains()')
where not exists (select 1 from cron.job where jobname = 'poll-chain-deposits');
