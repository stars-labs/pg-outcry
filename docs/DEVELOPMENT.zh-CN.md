[English](./DEVELOPMENT.md) · **中文**

# pg-outcry

一个纯 PostgreSQL 实现的中心化交易所（CEX）后端，构建在 Supabase 技术栈之上：
**PostgREST**（API）+ **Supabase Realtime**（行情 / 事件推送）+
**Supabase Auth / GoTrue**（身份认证）。撮合引擎是
[tolyo/open-outcry](https://github.com/tolyo/open-outcry) 的 PL/pgSQL 核心——
请求链路中没有任何 Go 服务。

## 目标（分阶段）

1. **将 SQL 撮合引擎迁移**到 Supabase 上，由 PostgREST + Realtime 驱动。✅ *已完成——阶段 1*
2. 账户余额 / 资金冻结 / 结算 / 风控 / 行情推送。
3. 后台 / 管理系统。
4. 钱包（充值与提现）。

扩展性方案（分片、分区、异步行情、WAL）与功能状态见 [`PERFORMANCE.zh-CN.md`](./PERFORMANCE.zh-CN.md)。

## 目录结构

| 路径 | 说明 |
|------|------|
| `web/` | OUTCRY 终端 Web 应用——WASM 订单簿 + OAuth2 + 实时推送（见 `web/README.md`） |
| `engine/` | 内置的 open-outcry SQL（goose 格式），`manifest.txt` = 依赖顺序 |
| `ext/oc_fastmath/` | 自研 C 扩展（原生银行家舍入，约 5.2× 于 PL/pgSQL）；`build.sh` 负责构建并加载 |
| `scripts/gen-migrations.sh` | 从 `engine/` 重新生成 `supabase/migrations/0*_engine_*.sql` |
| `supabase/migrations/0*_engine_*` | 生成的引擎 schema + 函数 |
| `supabase/migrations/00430_grants_security_definer.sql` | 将引擎函数设为 `SECURITY DEFINER` 并向 API 角色授予 EXECUTE |
| `supabase/migrations/00440_realtime.sql` | 将 `trade` / `trade_order` / `book_order` 发布到 Realtime |
| `supabase/migrations/00450_seed_dev.sql` | 货币、MASTER 资金实体、交易标的 |
| `supabase/migrations/00460_api_helpers.sql` | 读权限 + `find_instrument_account()` |
| `supabase/migrations/00470_stage2_concurrency_and_reads.sql` | 阶段 2：`submit_order`/`submit_cancel`（按标的的咨询锁）+ 读视图 |
| `supabase/migrations/00480_realtime_marketdata.sql` | 阶段 2：将 L2 `price_level` 发布到 Realtime |
| `supabase/migrations/00490_auth_rls.sql` | 阶段 3：GoTrue→`app_entity` 触发器、`place_order`/`cancel_order`、RLS、视图 `security_invoker` |
| `supabase/migrations/00500_wallet.sql` | 阶段 4：内部账本钱包（充值与提现的申请/批准/拒绝） |
| `supabase/migrations/00520_risk_controls.sql` | 按标的的风控（最大数量/名义金额/价格带），在 `place_order` 中强制执行 |
| `supabase/migrations/00550_backoffice.sql` | 账户状态、管理 RPC（停用/费率/风控）、`admin_audit_log` |
| `supabase/migrations/00510_realtime_wallet.sql` | 为私有推送流发布 `wallet_request` |
| `supabase/migrations/00560_wallet_idempotency.sql` | 钱包幂等键 |
| `supabase/migrations/00570_reconciliation.sql` | 仅追加（append-only）账本 + `reconcile()` 对账报告 |
| `supabase/migrations/00590_platform.sql` | 按角色的 `statement_timeout` |
| `supabase/migrations/00600_wal_reduction.sql` | 热表上的 Replica identity DEFAULT（减少 WAL） |
| `supabase/migrations/00580_cold_partitioning.sql` | trade 与各账本的按月 RANGE 分区（+ pg_cron 滚动） |
| `supabase/migrations/00610_async_marketdata.sql` | 通过 realtime broadcast 实现合并后的 L2 + 成交带（tape） |
| `supabase/migrations/00630_perf_indexes.sql` | 用于消除每笔成交时止损单顺序扫描的部分索引 |
| `supabase/migrations/00640_batch_settlement.sql` | 批量 DEBIT+CREDIT 账本 INSERT |
| `supabase/migrations/00620_hot_data.sql` | UNLOGGED 的 book_order + price_level（内存中）+ `rebuild_book()` |
| `supabase/migrations/00670_lockdown.sql` | 对所有引擎函数默认拒绝；仅重新授予 API 白名单（最后运行） |
| `supabase/migrations/00680_api_keys.sql` | 按用户 API key + 库内签发 JWT（`api_key_login`） |
| `supabase/migrations/00690_referral.sql` | 推荐码、一次性归属、taker 佣金计提 |
| `supabase/migrations/00700_withdrawal_whitelist.sql` | 提现地址白名单 + 滚动窗口限额 |
| `supabase/migrations/00710_chain_deposits.sql` | 链/资产/监听地址表 + 幂等 `credit_chain_deposit` |
| `supabase/migrations/00720_withdrawal_queue.sql` | 库内出金队列（`SKIP LOCKED` 认领 → 广播 → 确认） |
| `supabase/migrations/00730_staking.sql` | 质押池、惰性收益结算、基于 pgmq 的解质押 |
| `supabase/migrations/00740_margin.sql` | 全仓杠杆借还 + `pg_cron` 清算检查 |
| `supabase/migrations/00750_perp.sql` | 线性永续：标记价格、资金费率、清算 |
| `supabase/migrations/00760_grant_banker_round.sql` | 授权 `banker_round` + `stake_pool`/`perp_market` 的 RLS 策略 |
| `supabase/migrations/00770_ohlcv.sql` | 服务端 OHLCV K 线 RPC（`date_bin` 分桶，带护栏） |
| `supabase/migrations/00780_crypto_secp256k1_keccak.sql` | 纯 PL/pgSQL keccak256 + secp256k1（RFC6979）+ `evm_address` |
| `supabase/migrations/00790_admin_derivatives_controls.sql` | 质押池 / 杠杆参数 / 永续市场的管理 RPC |
| `supabase/migrations/00800_admin_wallet_chain_api_ops.sql` | 链配置、链上资产、API key 吊销的管理 RPC |
| `supabase/migrations/00810_hd_custody.sql` | Vault 主种子 → 每用户 EVM/Tron/Solana 充值地址 |
| `supabase/migrations/00820_chain_balance_poller.sql` | 库内余额增量充值轮询（`http` + `pg_cron`） |
| `supabase/migrations/00830_evm_withdrawal_signer.sql` | 库内 RLP/EIP-155 构造 + 签名 + 广播（EVM） |
| `supabase/migrations/00840_solana_tron_withdrawal.sql` | 库内 Solana wire 序列化 + Tron txID 签名广播 |
| `supabase/migrations/00850_token_assets_tron_trc20.sql` | USDT/USDC 币种 + TRC-20 转账签名 |
| `supabase/migrations/00860_hybrid_memo_deposits.sql` | 混合寻址：派生地址（EVM）vs 共享地址+memo（Tron/Solana） |
| `supabase/migrations/00870_reconcile_monitor.sql` | `run_reconcile_monitor()` 记录不变量破坏 → `reconcile_alert`（cron 5 分钟） |
| `supabase/migrations/00880_candle_cache.sql` | 持久化 `candle_1m` + 增量 `refresh_candle_1m()`（cron 1 分钟） |
| `supabase/migrations/00890_admin_rbac.sql` | 后台 RBAC 表、带审计的管理 RPC、链上背书资金强制 |
| `supabase/migrations/00900_stablecoin_tokens.sql` | ERC-20/SPL 签名、代币充值检测、显式 RLS 策略 |
| `supabase/migrations/00910_chain_backed_funding_reconcile.sql` | 托管对账 + 无链上背书资金的反冲 |
| `supabase/migrations/00920_ohlcv_from_cache.sql` | `ohlcv()` 改由 `candle_1m` 提供（缓存历史 + 实时尾部） |
| `supabase/migrations/00930_admin_rbac_switch.sql` | `admin_config.open_access` —— 把演示开放模式切换为真实 RBAC |
| `scripts/smoke-postgrest.sh` | 阶段 1 引擎测试，通过 HTTP `/rpc`（锁定后需要 `SERVICE` 密钥） |
| `scripts/smoke-realtime.mjs` | 断言一笔成交通过 websocket 广播 |
| `scripts/smoke-stage2.sh` | 咨询锁下单 + 读 API（部分成交、结算、冻结）；需要 `SERVICE` |
| `scripts/smoke-marketdata.mjs` | 断言 L2 `price_level` 更新通过 realtime 推送 |
| `scripts/smoke-stage3.sh` | GoTrue 注册 → 自动建账户、JWT 交易、RLS 隔离、API 白名单强制 |
| `scripts/smoke-stage4.sh` | 链上充值入账 + 钱包提现/拒绝账本 + 资金冻结 + 测试开放后台权限 |
| `scripts/smoke-stage5.sh` | 风控（价格带/限额）+ 后台（停用/费率/风控/审计） |
| `scripts/smoke-stage6.mjs` | 认证后的私有实时推送流（自己的订单/成交/钱包，无泄漏） |
| `examples/private-feed.mjs` | 可直接复制粘贴的私有推送流前端客户端 |
| `examples/md-ticker.mjs` | 100ms 行情打点器（刷新合并后的 L2 广播） |
| `scripts/smoke-stage7.sh` | 链上充值幂等 + 钱包幂等 + 核心/custody 对账报告 + 仅追加账本 |
| `scripts/smoke-stage8.sh` | 订单类型：MARKET / IOC / FOK 执行 + 终态 |
| `scripts/smoke-stage9.sh` | 止损单：STOPLOSS→MARKET / STOPLIMIT→LIMIT 触发激活 |

> `9xxx_` 的 grants/realtime/seed 迁移属于**阶段 1 的便利设置**：RLS 处于
> 关闭状态，引擎函数以定义者身份运行且没有按用户的作用域限制。阶段 3
> 用基于 Auth 的 RLS 取代这一套。

## 运行

```bash
supabase start                 # Postgres + PostgREST + Realtime + Auth (docker)
supabase db reset              # apply all migrations from scratch

export ANON="$(supabase status -o json | jq -r .ANON_KEY)"
export SERVICE="$(supabase status -o json | jq -r .SERVICE_ROLE_KEY)"

# Stage 1/2 — engine at the admin plane (service_role, since engine RPCs are locked down)
./scripts/smoke-postgrest.sh
./scripts/smoke-stage2.sh

# Realtime
npm i @supabase/supabase-js
node scripts/smoke-realtime.mjs
node scripts/smoke-marketdata.mjs

# Stage 3/4 — real GoTrue signup, JWT trading, RLS, wallet
./scripts/smoke-stage3.sh
./scripts/smoke-stage4.sh

# Risk controls + back-office admin (suspend / fees / risk / audit)
./scripts/smoke-stage5.sh
```

## 角色与安全模型

- **anon** —— 仅公开行情（通过表 SELECT 访问 `price_level`、`trade`、`instrument`、`currency`）。无 RPC。
- **authenticated**（用户 JWT）—— 自作用域 API：`place_order`、`cancel_order`、`my_deposit_address`、`request_withdrawal`、`current_app_entity_*`。RLS 将所有读取限制在调用者自身实体范围内。
- **authenticated operator**（用户 JWT）—— 当前托管测试版默认给每个已登录用户完整后台权限。`admin_operator_role` / `admin_role_permission` 保留用于后续收紧审批、账户、市场/风控、衍生品、安全与审计权限。
- **service_role** —— 仅服务端 root，用于 CI、可信任务、首次授权和原始引擎操作；浏览器后台不再需要它。
- `00670_lockdown.sql` 从 public/anon/authenticated 收回每个引擎函数的 EXECUTE 权限，并仅重新授予白名单，因此内部辅助函数（`create_trade`、`update_price_level`……）对客户端不可达。后续迁移会对自己新增的 RPC 显式 revoke/grant。

## 实时推送流

- **公开行情**（无需认证）：在频道 `md:<symbol>` 上订阅 **Broadcast**——事件 `l2`（合并后的订单簿，由 `examples/md-ticker.mjs` 每 100ms 刷新一次）与 `trade`（成交带，每笔成交推送）。`price_level`/`trade` 已分区，不再走 Postgres Changes。
- **私有的按用户推送流**（需认证）：调用 `supabase.realtime.setAuth(jwt)`，然后订阅 `trade_order`（订单生命周期 + 成交）与 `wallet_request`（充值/提现状态）。Realtime 会为每个订阅者逐表评估 RLS，因此客户端**只会收到自己的行**——无需 topic/userId 接线、无服务端中继。见 `examples/private-feed.mjs`。做市方与吃单方都会收到各自的 `FILLED` 更新；由于 `own_orders` / `own_wallet_requests` 策略对投递做了过滤，跨用户泄漏不可能发生。

## 引擎 API 注意事项（踩坑总结）

- `create_client(external_id)` 返回的是 **app_entity 的 `pub_id`（UUID）**，
  而非 external id。其他所有函数都以 `pub_id` 为键。`MASTER` 是唯一一个
  拥有字面量 pub_id（`'MASTER'`）的实体。
- `create_client` 只会开一个 **EUR** 货币账户；其他货币用
  `create_currency_account(pub_id, currency)` 开通。
- 用户资金通过链上充值路径入账（`my_deposit_address` + watcher；确定性测试可用 service-role `credit_chain_deposit`）。
- service-role 仍可为本地 seed/benchmark 直接调用 `process_transfer('DEPOSIT','MASTER', ...)`，但除内部产品结算外，这类用户入金会被 custody 对账报告为未上链资金。
  传 `fee_type=null` 可跳过手续费（未预置任何手续费行）。
- `process_trade_order`：`amount_param` 是**双边的基础（base）数量**；
  BUY 会在计价（quote）货币中冻结 `amount * price`。（Go 文档注释里说
  "BUY amount is in quote currency" 是有误导性的。）
- **MARKET 订单**用 `price = 0` 作为哨兵值（不是 null——`trade_order.price` 是
  NOT NULL；引擎在把止损单转为市价单时本身就会设 `price=0`）。支持的
  订单类型：`LIMIT / MARKET / STOPLOSS / STOPLIMIT`；TIF：`GTC / IOC / FOK / GTD / GTT`。
- MARKET 成交即便完全执行，由于引擎对 base/quote `open_amount` 的记账方式，
  也会报告终态为 `PARTIALLY_FILLED`——它们仍会产生正确的成交。
