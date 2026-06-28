# In-DB custody & on-chain testnet deposit/withdraw (pure PG)

Goal: the live demo supports **connect-wallet deposit + withdraw on public testnets**,
with **keys generated, addresses derived, and transactions signed entirely inside
PostgreSQL** (hosted Supabase = pure PL/pgSQL; self-host = optional native C extension
with identical function signatures for speed).

Chains: Ethereum **Sepolia**, **Solana devnet**, **Tron Nile**. Wallets: injected only
(MetaMask / Phantom / TronLink).

> ⚠️ TESTNET ONLY. The master seed lives in the DB (vault-encrypted) → DB access = fund
> control. Never custody real funds with this design.

## Stage 1: Crypto primitives (pure PL/pgSQL)
**Goal**: secp256k1 + keccak256 + ECDSA in-DB, no extension (works on hosted).
**Status**: ✅ Complete — `supabase/migrations/9970_crypto_secp256k1_keccak.sql`.
keccak256/keccak256_hex, secp_pubkey, secp_sign (RFC6979, low-s, v), secp_verify,
evm_address. Validated vs ethers/js-sha3: keccak all lengths 0..300; secp 30 random
(priv,z) r/s/v exact; anchor addrs priv=1→0x7e5f…, priv=2→0x2b5a…; sign+verify on
**local AND hosted**. Self-host C ext shadows same names (seam = function names).

## Stage 2: HD custody — seed, derivation, address assignment
**Goal**: in-DB master seed + per-user deposit addresses for all 3 chains; private keys
never stored, re-derived on demand for signing.
**Tests**: derived EVM/Tron/Solana addresses match an offline reference for a fixed
test seed; per-user determinism; addresses unique per (user,chain).
- `create extension pgsodium` (ed25519 for Solana) + `supabase_vault` for the seed.
- master seed = gen_random_bytes(32) → vault; helper `master_seed()` (definer, service).
- secp priv(user,chain) = HMAC-SHA512(seed, chain‖entity_id) mod n; ed25519 seed likewise.
- base58 + base58check encoders (Solana addr, Tron addr = base58check(0x41‖keccak-tail)).
- `user_chain_wallet(app_entity_id, chain, address)`; RPC `my_deposit_address(chain)`
  derives+stores+registers into `watched_address` (reuses 9920 deposit model).
**Status**: ✅ Complete — `supabase/migrations/9985_hd_custody.sql`. pgsodium + vault
seed; base58/base58check; `_master_seed` / `_derive_secp_priv` / `_derive_ed25519_seed`;
`evm_address` (9970) / `tron_address_from_priv` / `sol_address_from_eid`;
`my_deposit_address(chain)` RPC. Validated: base58/base58check match bs58/bs58check (40
inputs incl leading zeros); EVM addr == ethers.computeAddress(derived priv), Tron ==
bs58check(0x41‖keccak), Solana == bs58(ed25519 pub) for 4 entities (92/92); live REST
e2e (signup → 3 addresses, idempotent, watched). Applied to hosted.

## Stage 3: Deposits on testnet (in-DB watcher)
**Goal**: funds sent to a user's assigned address are auto-credited, fully in-DB.
**Tests**: decoder fixtures (exist); live credit on a real testnet tx (user-provided).
- Enable `supabase/chain/pollers.sql` on hosted: set chain.rpc_url (public endpoints),
  chain_asset mappings; pg_cron poll. Add native-ETH detection (block scan) or use a
  testnet ERC-20. Solana/Tron via existing decoders.
**Status**: Not Started.

## Stage 4: Withdrawals — in-DB sign + broadcast
**Goal**: request → in-DB sign → broadcast via pg_net, all on testnet.
**Tests**: produced raw tx matches ethers for a fixed (nonce,gas,to,value,chainId);
testnet broadcast confirms (user-provided treasury funds).
- EVM: RLP encode (legacy/EIP-1559), keccak, secp_sign, assemble, `eth_sendRawTransaction`
  via pg_net; nonce/gas via pg_net. Treasury = derived index 0, funded by user faucet.
- Tron: TronGrid createtransaction → sign sha256(raw_data) → broadcast.
- Solana: build transfer + recent blockhash → ed25519 sign (pgsodium) → sendTransaction.
- Wire into existing `next_withdrawal_to_sign`/`mark_withdrawal_broadcast` (9925), driven
  by pg_cron instead of the external signer.
**Status**: Not Started.

## Stage 5: Frontend — wallet connect + UX
**Goal**: Deposits tab shows the assigned per-chain address (QR/copy) + injected-wallet
"send" helper; Withdraw tab targets the connected wallet address.
**Tests**: chrome-devtools — connect flow, address shows, request submits.
**Status**: Not Started.

## Stage 6: Deploy + verify on testnet
**Goal**: end-to-end on the hosted demo.
**Blockers (user-provided)**: testnet faucet funds to the generated treasury addresses
(ETH Sepolia, SOL devnet, TRX Nile); confirm public RPC endpoints are acceptable.
**Status**: Not Started.
