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
| `supabase/migrations/9000_grants_security_definer.sql` | 将引擎函数设为 `SECURITY DEFINER` 并向 API 角色授予 EXECUTE |
| `supabase/migrations/9001_realtime.sql` | 将 `trade` / `trade_order` / `book_order` 发布到 Realtime |
| `supabase/migrations/9002_seed_dev.sql` | 货币、MASTER 资金实体、交易标的 |
| `supabase/migrations/9003_api_helpers.sql` | 读权限 + `find_instrument_account()` |
| `supabase/migrations/9100_stage2_concurrency_and_reads.sql` | 阶段 2：`submit_order`/`submit_cancel`（按标的的咨询锁）+ 读视图 |
| `supabase/migrations/9101_realtime_marketdata.sql` | 阶段 2：将 L2 `price_level` 发布到 Realtime |
| `supabase/migrations/9200_auth_rls.sql` | 阶段 3：GoTrue→`app_entity` 触发器、`place_order`/`cancel_order`、RLS、视图 `security_invoker` |
| `supabase/migrations/9300_wallet.sql` | 阶段 4：内部账本钱包（充值与提现的申请/批准/拒绝） |
| `supabase/migrations/9500_risk_controls.sql` | 按标的的风控（最大数量/名义金额/价格带），在 `place_order` 中强制执行 |
| `supabase/migrations/9600_backoffice.sql` | 账户状态、管理 RPC（停用/费率/风控）、`admin_audit_log` |
| `supabase/migrations/9310_realtime_wallet.sql` | 为私有推送流发布 `wallet_request` |
| `supabase/migrations/9320_wallet_idempotency.sql` | 钱包幂等键 |
| `supabase/migrations/9330_reconciliation.sql` | 仅追加（append-only）账本 + `reconcile()` 对账报告 |
| `supabase/migrations/9700_platform.sql` | 按角色的 `statement_timeout` |
| `supabase/migrations/9710_wal_reduction.sql` | 热表上的 Replica identity DEFAULT（减少 WAL） |
| `supabase/migrations/9640_cold_partitioning.sql` | trade 与各账本的按月 RANGE 分区（+ pg_cron 滚动） |
| `supabase/migrations/9720_async_marketdata.sql` | 通过 realtime broadcast 实现合并后的 L2 + 成交带（tape） |
| `supabase/migrations/9750_perf_indexes.sql` | 用于消除每笔成交时止损单顺序扫描的部分索引 |
| `supabase/migrations/9760_batch_settlement.sql` | 批量 DEBIT+CREDIT 账本 INSERT |
| `supabase/migrations/9730_hot_data.sql` | UNLOGGED 的 book_order + price_level（内存中）+ `rebuild_book()` |
| `supabase/migrations/9900_lockdown.sql` | 对所有引擎函数默认拒绝；仅重新授予 API 白名单（最后运行） |
| `scripts/smoke-postgrest.sh` | 阶段 1 引擎测试，通过 HTTP `/rpc`（锁定后需要 `SERVICE` 密钥） |
| `scripts/smoke-realtime.mjs` | 断言一笔成交通过 websocket 广播 |
| `scripts/smoke-stage2.sh` | 咨询锁下单 + 读 API（部分成交、结算、冻结）；需要 `SERVICE` |
| `scripts/smoke-marketdata.mjs` | 断言 L2 `price_level` 更新通过 realtime 推送 |
| `scripts/smoke-stage3.sh` | GoTrue 注册 → 自动建账户、JWT 交易、RLS 隔离、仅管理员的权限强制 |
| `scripts/smoke-stage4.sh` | 钱包充值/提现/拒绝账本 + 资金冻结 + 仅管理员 |
| `scripts/smoke-stage5.sh` | 风控（价格带/限额）+ 后台（停用/费率/风控/审计） |
| `scripts/smoke-stage6.mjs` | 认证后的私有实时推送流（自己的订单/成交/钱包，无泄漏） |
| `examples/private-feed.mjs` | 可直接复制粘贴的私有推送流前端客户端 |
| `examples/md-ticker.mjs` | 100ms 行情打点器（刷新合并后的 L2 广播） |
| `scripts/smoke-stage7.sh` | 钱包幂等 + 对账报告 + 仅追加账本 |
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
- **authenticated**（用户 JWT）—— 自作用域 API：`place_order`、`cancel_order`、`request_deposit`、`request_withdrawal`、`current_app_entity_*`。RLS 将所有读取限制在调用者自身实体范围内。
- **service_role**（后台）—— 完整引擎 + 管理 RPC（`process_transfer`、`approve_wallet_request`……）；绕过 RLS。
- `9900_lockdown.sql` 从 public/anon/authenticated 收回每个引擎函数的 EXECUTE 权限，并仅重新授予白名单，因此内部辅助函数（`create_trade`、`update_price_level`……）对客户端不可达。它最后运行，因此也覆盖后续迁移新增的函数。

## 实时推送流

- **公开行情**（无需认证）：在频道 `md:<symbol>` 上订阅 **Broadcast**——事件 `l2`（合并后的订单簿，由 `examples/md-ticker.mjs` 每 100ms 刷新一次）与 `trade`（成交带，每笔成交推送）。`price_level`/`trade` 已分区，不再走 Postgres Changes。
- **私有的按用户推送流**（需认证）：调用 `supabase.realtime.setAuth(jwt)`，然后订阅 `trade_order`（订单生命周期 + 成交）与 `wallet_request`（充值/提现状态）。Realtime 会为每个订阅者逐表评估 RLS，因此客户端**只会收到自己的行**——无需 topic/userId 接线、无服务端中继。见 `examples/private-feed.mjs`。做市方与吃单方都会收到各自的 `FILLED` 更新；由于 `own_orders` / `own_wallet_requests` 策略对投递做了过滤，跨用户泄漏不可能发生。

## 引擎 API 注意事项（踩坑总结）

- `create_client(external_id)` 返回的是 **app_entity 的 `pub_id`（UUID）**，
  而非 external id。其他所有函数都以 `pub_id` 为键。`MASTER` 是唯一一个
  拥有字面量 pub_id（`'MASTER'`）的实体。
- `create_client` 只会开一个 **EUR** 货币账户；其他货币用
  `create_currency_account(pub_id, currency)` 开通。
- 通过 `process_transfer('DEPOSIT','MASTER', amount, currency, to_pub_id, ref, details, fee_type)` 入金。
  传 `fee_type=null` 可跳过手续费（未预置任何手续费行）。
- `process_trade_order`：`amount_param` 是**双边的基础（base）数量**；
  BUY 会在计价（quote）货币中冻结 `amount * price`。（Go 文档注释里说
  "BUY amount is in quote currency" 是有误导性的。）
- **MARKET 订单**用 `price = 0` 作为哨兵值（不是 null——`trade_order.price` 是
  NOT NULL；引擎在把止损单转为市价单时本身就会设 `price=0`）。支持的
  订单类型：`LIMIT / MARKET / STOPLOSS / STOPLIMIT`；TIF：`GTC / IOC / FOK / GTD / GTT`。
- MARKET 成交即便完全执行，由于引擎对 base/quote `open_amount` 的记账方式，
  也会报告终态为 `PARTIALLY_FILLED`——它们仍会产生正确的成交。
