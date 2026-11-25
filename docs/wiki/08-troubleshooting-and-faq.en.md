**English** · [中文](./08-troubleshooting-and-faq.md)

# Chapter 8: Complete Error Code Dictionary, FAQ & CEX Glossary

[← Previous: Back-Office & Proof of Solvency](./07-backoffice-and-reconciliation.en.md) · **Chapter 8** · [Back to Wiki Master Index →](./README.en.md)

---

Whenever an action hits a pre-trade risk guardrail, balance hold, or address validation rule, OUTCRY surfaces a coral-red toast in the bottom-right corner of the terminal (or returns a structured JSON error from PostgREST). This chapter catalogs **every error message in the venue, its exact root cause, and a 60-second fix**, followed by the 12 most common trader FAQs and a CEX glossary.

---

## 8.1 Complete Toast & API Error Code Dictionary

> *Tip: The web terminal formats snake_case error codes with spaces (e.g. `insufficient_available_balance` appears as `insufficient available balance`). Press `Ctrl + F` / `Cmd + F` to jump straight to any message.*

### A. Authentication & Account Status

| Toast / API Error Message | Root Cause | 60-Second Fix |
|---|---|---|
| `email + password required` | Email or password field was left blank when submitting the auth form. | Fill in both email and password, then click submit. |
| `Invalid login credentials` | Unknown email or wrong password in Sign-In mode (or trying to register a brand-new user while still in Sign-In mode). | For a new account, click **`NO ACCOUNT? REGISTER →`** at the bottom so the button says `CREATE ACCOUNT →`. |
| `User already registered` | Submitting Sign-Up with an email address that already exists. | Click **`HAVE AN ACCOUNT? SIGN IN →`** to switch back to Sign-In mode. |
| `not authenticated` / `no account` | Session JWT expired or missing `Authorization: Bearer` header on a protected RPC. | Refresh and sign in again; for trading bots, call `api_key_login` to mint a fresh JWT. |
| `account suspended` / `entity suspended` | Account has been frozen by an administrator (`Suspended`); order entry and withdrawals are blocked. | Contact venue support / ask an admin to click `Unsuspend` in `admin.html → Accounts`. |

### B. Spot Trading & Pre-Trade Risk Guardrails

| Toast / API Error Message | Root Cause | 60-Second Fix |
|---|---|---|
| `insufficient funds` / `insufficient available balance` | Free `Available` balance is smaller than the order cost or sell quantity. | 1. Check **`OPEN ORDERS`** for resting limit orders locking funds in `Reserved` and click **`✕`** to cancel;<br/>2. Or top up via `Wallet → Deposit`. |
| `risk max order amount: X > Y` | Single-order quantity `X` exceeds the instrument's `max_order_amount` `Y` (default `100`). *Note: `BUY MARKET` sends quote budget as `amount_param`, which can exceed `100` on high-priced pairs.* | Split large orders into smaller clips, or use **`LIMIT` + `IOC`** with base quantity (`BTC`); admins can also raise `max amt` in `Markets → Instrument Risk`. |
| `risk max order notional: X > Y` | Single-order notional (`price × amount = X`) exceeds `max_order_notional` `Y` (default `100,000 USDT`). | Reduce order size (e.g. $\le 1.45\text{ BTC}$ at `68,500 USDT`) and execute in tranches. |
| `risk price band: P beyond B pct band of reference R` | Fat-finger price band tripped: limit price `P` deviates more than `±B%` (default `±10%`) from reference price `R`, or a `MARKET` order (`price=0`) was sent while a price band is active. | 1. Check your limit price for extra/missing digits so it sits within `±10%` of spot;<br/>2. For immediate market sweeps, use **`LIMIT`** + protective cap (e.g. `ref × 1.01`) + **`IOC`**. |
| `no asks to estimate market buy` | The ask side of the order book is completely empty, so market buy cost cannot be estimated. | Place a **`LIMIT`** buy order instead to rest on the bid book. |
| `instrument not enabled: <SYM>` | Instrument has been disabled/delisted (such as legacy `EUR` pairs). | Switch to an active pair in the top bar (e.g. `BTC_USDT`). |

### C. Deposits, Whitelisting & On-Chain Withdrawals

| Toast / API Error Message | Root Cause | 60-Second Fix |
|---|---|---|
| `whitelist an address first` / `address not whitelisted or cooling` | Destination address is not yet whitelisted on your account or is still in its cooldown window. | In `Wallet → Withdraw`, paste the address, click **`WHITELIST`**, confirm it shows green **`usable`**, and select it in the dropdown. |
| `withdrawal limit exceeded: A + B > L per 24h` | Prior 24h withdrawals `A` (`PENDING` + `APPROVED`) plus current amount `B` exceed rolling 24h cap `L` (`5 BTC` / `50,000 USDT`). | Lower the withdrawal amount to $\le L - A$, or wait for older requests to roll past the 24h window. |
| `no currency account: <CUR>` | Your account has never held or initialized currency `<CUR>`. | Check the `Debits your <CUR> balance` hint and deposit/acquire `<CUR>` first. |
| `btc address not testnet: <ADDR>` | Mainnet Bitcoin address (`bc1q…`, `1…`, `3…`) supplied on Testnet4. | Provide a valid **Bitcoin Testnet4** address (`tb1q…`, `tb1p…`, `m/n…`, or `2…`). |
| `btc address bad checksum` / `mixed case` | Typo, truncated character, or mixed case in a Bech32/Base58 address. | Copy-paste the address directly from your external wallet instead of typing by hand. |
| `btc insufficient hot wallet` | (Signer stage) Confirmed hot-wallet UTXOs are temporarily insufficient while a recent change output awaits 1 block confirmation. | No user action needed! Once the change UTXO mines 1 confirmation, `pg_cron` signs and broadcasts automatically. |

### D. Perpetuals, Cross-Margin & Staking

| Toast / API Error Message | Root Cause | 60-Second Fix |
|---|---|---|
| `position exists close first` | You already hold an open `BTC-PERP` position (net-position model per market). | Click **`close`** on your current position in `YOUR POSITIONS`, then open the new desired size/direction. |
| `insufficient margin: need X got Y` | Supplied perpetual margin `Y` is below the `10×` minimum initial margin `X`. | Increase `margin` to at least $|\text{Size}| \times \text{Mark} / 10$ (with extra buffer above the `5%` maintenance line). |
| `no mark price` | Perpetual market has no mark price yet because no reference trade has occurred. | Execute a spot reference trade or wait for `update_perp_mark()`. |
| `exceeds max leverage` | Borrowing would push total cross-margin debt above $(L_{\max}-1) \times \text{Equity}$ (`2 × Equity`). | Borrow a smaller size or deposit additional spot collateral first. |
| `insufficient staked` | Unstake quantity exceeds your staked principal in that pool. | Click **`unstake all`** on the position row to unbond your exact full principal. |

---

## 8.2 Top 12 Trader FAQs

1. **Q: I sent a deposit from my wallet a minute ago — why is `AVAILABLE` still `0`?**
   - **A**: Open `Wallet → Deposit` and check **`DETECTED DEPOSITS`**. An amber **`pending…`** badge means the watcher already detected your transaction and is waiting for finality confirmations (`2` blocks on BTC Testnet4, `12` on Sepolia, `19` on Tron Nile, `32` on Solana). As soon as confirmations finish, it turns green **`credited`** and updates `AVAILABLE` automatically.
2. **Q: My `Total` balance didn't drop, so why does placing an order say `insufficient available balance`?**
   - **A**: Look next to `AVAILABLE` for an amber **`+xxx rsv`** hold! Resting limit orders (`OPEN ORDERS` tab) and `PENDING` withdrawals (`WALLET` tab) lock funds in `Reserved`. Click **`✕`** on unneeded open orders to free them instantly.
3. **Q: Can I cancel a withdrawal if I change my mind?**
   - **A**: While status is still **`PENDING`** (before admin approval and on-chain signing), an operator can click **`REJECT`** in `admin.html → Treasury` to return 100% of the locked funds to your `Available` balance. Once **`BROADCAST` / `CONFIRMED`** on-chain, blockchain transactions are irreversible.
4. **Q: How much withdrawal fee is deducted from a `0.25 BTC` payout?**
   - **A**: **Zero (`0`) fee deducted — you receive 100% (`0.25000000 BTC`)!** On-chain miner fees are absorbed by the venue's hot-wallet treasury change output.
5. **Q: Why did depositing Sepolia ETH / Nile TRX / Testnet SOL credit `EUR`?**
   - **A**: Testnet native gas tokens map to the demo fiat quote currency `EUR` (`1 ETH → 2,500 EUR`, `1 SOL → 150 EUR`, `1 TRX → 0.10 EUR`). To trade `BTC_USDT` or `BTC-PERP` directly, deposit **`BTC` (`Bitcoin · testnet4`)** and **`USDT` (`TRC-20 · Nile`)**.
6. **Q: Is there a shortcut to fill `LIMIT PRICE` without typing 5-digit numbers?**
   - **A**: Yes — click any bid or ask row in `ORDER BOOK · L2` on the left to copy that exact price into `LIMIT PRICE` and trigger an instant WASM cost preview.
7. **Q: Do my chart trendlines disappear if I refresh the browser?**
   - **A**: **No.** Drawings persist automatically per instrument in `localStorage` (`oc_draw_BTC_USDT`) anchored to `(unix_timestamp, price)`. Click **`⌫`** at the bottom of the drawing rail to clear them.
8. **Q: Why didn't my principal return to `AVAILABLE` right after clicking `unstake all` in `Earn`?**
   - **A**: Accrued yield settles immediately to `AVAILABLE`, while staked principal enters the `pgmq` unbonding queue (`7 days` by default) and returns automatically upon maturity.
9. **Q: Why was my withdrawal approved immediately and all my open quotes cancelled when using a Market Maker account?**
   - **A**: Migration `00190` implements atomic maker self-withdrawal: withdrawing from the active house market-maker account disables quoting, cancels resting quotes to unlock reserved inventory, auto-approves the debit, and queues on-chain signing in one transaction.
10. **Q: How can anyone verify the venue is 100% solvent right now?**
    - **A**: Open `admin.html` and check **`recon ALL PASS`** under `RECONCILIATION · INVARIANTS`: all 7 ledger + custody checks passing with `FUNDING EXPOSURE = 0` proves double-entry conservation and 100% chain-backed customer balances.
11. **Q: What if I lose the `secret` for an API Key?**
    - **A**: Secrets are hashed one-way and never stored in plaintext. Click **`revoke`** on the old key in the `API` modal and mint a new key.
12. **Q: Can I still trade if the top-right badge switches from green `live · realtime` to red `polling`?**
    - **A**: **Yes!** `polling` simply means WebSocket broadcasts fell back to 1.5-second HTTP polling; order entry, cancellations, and withdrawals execute over independent transactional PostgREST HTTPS calls.

---

## 8.3 Cryptocurrency Exchange Glossary

| Term | Concise Definition |
|---|---|
| **Maker** | A limit order that rests on the order book instead of matching immediately, **adding liquidity** to the venue. |
| **Taker** | A market or marketable limit order that crosses the spread and matches immediately against resting orders, **consuming liquidity**. |
| **L2 Order Book** | Real-time market depth aggregated by price level across all resting bids and asks. |
| **Spread & bps** | `Best Ask − Best Bid`; `1 bp` (basis point) = `0.01%`. Tighter spreads mean lower execution friction. |
| **VWAP** | Volume-Weighted Average Price across multiple price levels swept by a single order. |
| **GTC / IOC / FOK** | Time-in-Force policies: Good-Til-Cancelled (`GTC`), Immediate-Or-Cancel (`IOC`), and Fill-Or-Kill (`FOK`). |
| **Reserved** | Funds temporarily locked by open limit orders or `PENDING` withdrawals (`Total = Available + Reserved`). |
| **UTXO** | Unspent Transaction Output — Bitcoin's discrete coin model spent as inputs and returned as treasury change during signing. |
| **P2WPKH / Native SegWit** | Bech32 native SegWit Bitcoin standard (`tb1q…` on testnet, `bc1q…` on mainnet) offering lower miner fees and malleability protection. |
| **Double-Entry Ledger** | Accounting discipline requiring every balance transfer to record equal debit and credit entries summing algebraically to zero. |
| **RLS (Row-Level Security)** | Kernel-level PostgreSQL access control ensuring each authenticated JWT can query only rows belonging to its own entity. |

---

**[← Back to Chapter 7: Back-Office & Proof of Solvency](./07-backoffice-and-reconciliation.en.md)** · **[🏠 Back to Wiki Master Index](./README.en.md)**
