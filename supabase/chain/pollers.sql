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

-- hex (no 0x) -> numeric, overflow-safe for 256-bit EVM words (int64 would overflow).
create or replace function hex_to_numeric(h text) returns numeric
  language sql immutable as $$
  select coalesce(sum(('x' || substr(h, i, 1))::bit(4)::int * power(16::numeric, length(h) - i)), 0)
  from generate_series(1, length(h)) i;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Pure DECODERS (no network). The poll_* functions below do the HTTP call, then
-- delegate JSON→deposit parsing to these so the fragile, chain-specific extraction
-- is unit-testable from fixtures. See scripts/test-pollers-decode.sh.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── EVM: decode an eth_getLogs `result` array of ERC-20 Transfer logs ────────────
-- topics[2] is the 32-byte indexed `to` (address = last 20 bytes / 40 hex chars).
-- `data` is the 256-bit uint256 amount — MUST be parsed with hex_to_numeric (int64
-- ::bit(64) overflows and errors on real values). Returns raw `block` and a
-- 10^decimals-scaled `amount`; the caller computes confirmations from block height.
create or replace function decode_evm_logs(resp jsonb, token text, decimals int, watched_lower text[])
  returns table(txid text, to_addr text, log_index int, amount numeric, block bigint)
  language sql stable as $$
  select lg->>'transactionHash',
         '0x' || right(lg->'topics'->>2, 40),
         hex_to_numeric(substr(lg->>'logIndex', 3))::int,
         hex_to_numeric(substr(lg->>'data', 3)) / power(10, decimals),
         hex_to_numeric(substr(lg->>'blockNumber', 3))::bigint
  from jsonb_array_elements(resp->'result') as lg
  where lower('0x' || right(lg->'topics'->>2, 40)) = any(watched_lower);
$$;

-- ── Tron: decode a TronGrid /transactions/trc20 response ─────────────────────────
-- Real shape: {"data":[{"transaction_id":"..","token_info":{"address":"T..",
--   "decimals":6,"symbol":"USDT"},"from":"T..","to":"T..","value":"1500000",
--   "type":"Transfer"}]}. NOTE `value` is a STRING of the raw integer (can exceed
-- int64) — read it with ->> and cast to numeric, never to bigint. Returns the RAW
-- amount; the caller divides by 10^decimals. Only Transfer rows to a watched `to`.
create or replace function decode_tron_trc20(resp jsonb, watched_lower text[])
  returns table(txid text, to_addr text, token text, amount_raw numeric)
  language sql immutable as $$
  select d->>'transaction_id',
         d->>'to',
         lower(d->'token_info'->>'address'),
         (d->>'value')::numeric
  from jsonb_array_elements(resp->'data') as d
  where d->>'type' = 'Transfer'
    and lower(d->>'to') = any(watched_lower);
$$;

-- ── Solana: lamports gained by `address` in a getTransaction(jsonParsed) result ──
-- In jsonParsed encoding result.transaction.message.accountKeys is an array of
-- OBJECTS {"pubkey":..,"signer":..,"writable":..} — NOT plain strings — so the
-- index must be found via elem->>'pubkey'. lamports = postBalances[i]-preBalances[i].
-- Returns NULL when `address` is not in the account list. Raw lamports (caller /1e9).
create or replace function decode_solana_credit(tx jsonb, address text) returns numeric
  language sql immutable as $$
  select (tx->'meta'->'postBalances'->>i.idx)::numeric
       - (tx->'meta'->'preBalances'->>i.idx)::numeric
  from (
    select (ord - 1)::int as idx
    from jsonb_array_elements(tx->'transaction'->'message'->'accountKeys')
           with ordinality as e(elem, ord)
    where elem->>'pubkey' = address
    limit 1
  ) i;
$$;

-- ── Ethereum (Sepolia) — ERC-20 Transfer logs via eth_getLogs ───────────────────
-- Transfer(address,address,uint256) topic0:
--   0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef
create or replace function poll_evm(chain_param text) returns int
  language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare
  cfg chain%rowtype; a chain_asset%rowtype; latest bigint; fromb bigint; nb int := 0;
  body jsonb; resp jsonb; d record; watched text[];
begin
  select * into cfg from chain where name = chain_param and enabled and kind = 'evm';
  if not found then return 0; end if;

  -- latest block height
  resp := (extensions.http_post(cfg.rpc_url,
            '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}', 'application/json')).content::jsonb;
  latest := hex_to_numeric(substr(resp->>'result', 3))::bigint;
  select last_scanned::bigint into fromb from chain_cursor where chain = chain_param;
  fromb := greatest(coalesce(fromb, latest - 5000) + 1, 0);

  select array_agg(lower(address)) into watched from watched_address where chain = chain_param;
  watched := coalesce(watched, '{}');

  for a in select * from chain_asset where chain = chain_param and token <> 'native' loop
    body := jsonb_build_object('jsonrpc','2.0','id',1,'method','eth_getLogs','params',
      jsonb_build_array(jsonb_build_object(
        'fromBlock', to_hex(fromb), 'toBlock', to_hex(latest), 'address', a.token,
        'topics', jsonb_build_array('0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'))));
    resp := (extensions.http_post(cfg.rpc_url, body::text, 'application/json')).content::jsonb;
    for d in select * from decode_evm_logs(resp, a.token, a.decimals, watched) loop
      perform credit_chain_deposit(chain_param, d.txid, d.log_index,
                d.to_addr, a.currency, d.amount, (latest - d.block)::int);
      nb := nb + 1;
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
declare cfg chain%rowtype; w record; resp jsonb; d record; cur text; dec int; nb int := 0; li int;
begin
  select * into cfg from chain where name = chain_param and enabled and kind = 'tron';
  if not found then return 0; end if;
  for w in select address from watched_address where chain = chain_param loop
    resp := (extensions.http_get(cfg.rpc_url || '/v1/accounts/' || w.address ||
              '/transactions/trc20?only_confirmed=true&limit=50')).content::jsonb;
    li := 0;
    for d in select * from decode_tron_trc20(resp, array[lower(w.address)]) loop
      select currency, decimals into cur, dec from chain_asset
        where chain = chain_param and token = d.token;
      if cur is not null then
        -- one tx can carry several TRC-20 transfers; index them so the (chain,txid,
        -- log_index) idempotency key stays unique instead of colliding on 0.
        perform credit_chain_deposit(chain_param, d.txid, li, w.address, cur,
                  d.amount_raw / power(10, dec), cfg.confirmations);
        nb := nb + 1;
        li := li + 1;
      end if;
    end loop;
  end loop;
  return nb;
end $$;

-- ── Solana (testnet) — native SOL via getSignaturesForAddress + getTransaction ───
create or replace function poll_solana(chain_param text) returns int
  language plpgsql security definer set search_path = public, extensions, pg_temp
as $$
declare cfg chain%rowtype; w record; a chain_asset%rowtype; sigs jsonb; s jsonb; tx jsonb; nb int := 0; lamports numeric; amt numeric;
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
        lamports := decode_solana_credit(tx, w.address);
        if lamports is not null then
          amt := lamports / power(10, a.decimals);
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
