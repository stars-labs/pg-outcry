[English](./DEVELOPMENT.md) · **中文**

# pg-outcry

一个纯 PostgreSQL 实现的中心化交易所（CEX）后端，构建在 Supabase 技术栈之上：
**PostgREST**（API）+ **Supabase Realtime**（行情 / 事件推送）+
**Supabase Auth / GoTrue**（身份认证）。撮合引擎是
[tolyo/open-outcry](https://github.com/tolyo/open-outcry) 的 PL/pgSQL 核心——
请求链路中没有任何 Go 服务。

### 目标（分阶段）

1. **将 SQL 撮合引擎迁移**到 Supabase 上，由 PostgREST + Realtime 驱动。✅ *已完成——阶段 1*
2. 账户余额 / 资金冻结 / 结算 / 风控 / 行情推送。
3. 后台 / 管理系统。
4. 钱包（充值与提现）。

扩展性方案（分片、分区、异步行情、WAL）与功能状态见 [`PERFORMANCE.zh-CN.md`](./PERFORMANCE.zh-CN.md)。

### 目录结构

| 路径 | 说明 |
|------|------|
| `web/` | OUTCRY 终端 Web 应用——WASM 订单簿 + OAuth2 + 实时推送（见 `web/README.md`） |
| `engine/` | 内置的 open-outcry SQL（goose 格式），`manifest.txt` = 依赖顺序 |
| `ext/oc_fastmath/` | 自研 C 扩展（原生银行家舍入，约 5.2× 于 PL/pgSQL）；`build.sh` 负责构建并加载 |
| `supabase/migrations/00010_engine.sql` | 由 `engine/`（vendored open-outcry）生成：核心 schema + 撮合/结算函数 |
| `supabase/migrations/00020_platform_base.sql` | `SECURITY DEFINER` 授权、Realtime publication、种子数据（币种/MASTER/交易对）、读视图 + `submit_order` |
| `supabase/migrations/00030_auth_wallet_risk.sql` | GoTrue→`app_entity` 触发器、RLS、`place_order`/`cancel_order`、内部钱包、预交易风控、后台基础、钱包幂等 |
| `supabase/migrations/00040_ledger_perf_lockdown.sql` | 只追加账本 + `reconcile()`、月度分区、异步行情、UNLOGGED 热点订单簿、性能索引、批量结算、默认拒绝锁定 |
| `supabase/migrations/00050_features_crypto.sql` | API key、推荐返佣、提现白名单、链上充值 + 出金队列、质押/杠杆/永续、OHLCV、纯 PL/pgSQL secp256k1+keccak256 |
| `supabase/migrations/00060_custody_chain.sql` | 管理端产品/链 RPC、基于 vault 种子的 HD 托管、余额轮询、库内 EVM/Tron/Solana 签名广播、TRC-20、混合 memo 充值 |
| `supabase/migrations/00070_backoffice_rbac.sql` | 对账监控、1m 蜡烛缓存、后台 RBAC + 审计、ERC-20/SPL 代币、链上背书资金强制、RBAC 配置开关 |
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

### 运行

```bash
supabase start                 # Postgres + PostgREST + Realtime + Auth (docker)
supabase db reset              # apply all migrations from scratch

export ANON="$(supabase status -o json | jq -r .ANON_KEY)"
export SERVICE="$(supabase status -o json | jq -r .SERVICE_ROLE_KEY)"

## Stage 1/2 — engine at the admin plane (service_role, since engine RPCs are locked down)
./scripts/smoke-postgrest.sh
./scripts/smoke-stage2.sh

## Realtime
npm i @supabase/supabase-js
node scripts/smoke-realtime.mjs
node scripts/smoke-marketdata.mjs

## Stage 3/4 — real GoTrue signup, JWT trading, RLS, wallet
./scripts/smoke-stage3.sh
./scripts/smoke-stage4.sh

## Risk controls + back-office admin (suspend / fees / risk / audit)
./scripts/smoke-stage5.sh
```

### 角色与安全模型

- **anon** —— 仅公开行情（通过表 SELECT 访问 `price_level`、`trade`、`instrument`、`currency`）。无 RPC。
- **authenticated**（用户 JWT）—— 自作用域 API：`place_order`、`cancel_order`、`my_deposit_address`、`request_withdrawal`、`current_app_entity_*`。RLS 将所有读取限制在调用者自身实体范围内。
- **authenticated operator**（用户 JWT）—— 当前托管测试版默认给每个已登录用户完整后台权限。`admin_operator_role` / `admin_role_permission` 保留用于后续收紧审批、账户、市场/风控、衍生品、安全与审计权限。
- **service_role** —— 仅服务端 root，用于 CI、可信任务、首次授权和原始引擎操作；浏览器后台不再需要它。
- `00040_ledger_perf_lockdown.sql` 从 public/anon/authenticated 收回每个引擎函数的 EXECUTE 权限，并仅重新授予白名单，因此内部辅助函数（`create_trade`、`update_price_level`……）对客户端不可达。后续迁移会对自己新增的 RPC 显式 revoke/grant。

### 实时推送流

- **公开行情**（无需认证）：在频道 `md:<symbol>` 上订阅 **Broadcast**——事件 `l2`（合并后的订单簿，由 `examples/md-ticker.mjs` 每 100ms 刷新一次）与 `trade`（成交带，每笔成交推送）。`price_level`/`trade` 已分区，不再走 Postgres Changes。
- **私有的按用户推送流**（需认证）：调用 `supabase.realtime.setAuth(jwt)`，然后订阅 `trade_order`（订单生命周期 + 成交）与 `wallet_request`（充值/提现状态）。Realtime 会为每个订阅者逐表评估 RLS，因此客户端**只会收到自己的行**——无需 topic/userId 接线、无服务端中继。见 `examples/private-feed.mjs`。做市方与吃单方都会收到各自的 `FILLED` 更新；由于 `own_orders` / `own_wallet_requests` 策略对投递做了过滤，跨用户泄漏不可能发生。

### 引擎 API 注意事项（踩坑总结）

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

---

## 迁移编号规范

所有迁移使用**5 位等宽、步长 10 的数字前缀**：`00010_`、`00020_` … `00910_`。

```
supabase/migrations/00010_engine.sql
supabase/migrations/00010_engine.sql
...
supabase/migrations/00070_backoffice_rbac.sql
```

### 为什么要等宽

Supabase CLI 按**文件名字典序**应用迁移，并把第一个 `_` 之前的数字当作迁移的
**version**（即 `schema_migrations` 的主键）。在旧的混合宽度方案下，这两点反复
坑到我们：

- **宽度不一致时，字典序 ≠ 数值序。** `'9' (0x39) < '_' (0x5F)`，所以
  `99999_admin_rbac.sql` 排在 `9999_stablecoin_tokens.sql` **之前**；而
  `100000_…` 因为 `'1' < '9'`，排到了整个序列的**前部**而不是末尾。
- **version 必须唯一。** `9999_a.sql` 和 `9999_b.sql` 都解析成 version `9999`，
  会撞 `schema_migrations` 主键，导致 `db reset` / `db push` 失败。
- **前缀必须是数字。** 字母前缀（`A001_…`）会被 CLI **静默跳过** —— 迁移永远
  不会执行，且不报任何错误。

前缀等宽之后，字典序**就是**数值序，上述排序陷阱全部消失。

### 新增迁移

- **追加**：取当前最后一个文件之后的下一个 10 的倍数。
- **插入到两个迁移之间**：使用间隙中的空号（例如在 `00560_` 和 `00570_` 之间用
  `00565_`）。步长 10 的留白正是为此准备的。
- 不要复用编号；也不要修改**已经应用到线上数据库**的迁移的前缀（见下）。

### 给已部署的数据库重新编号

重命名迁移文件会改变它的 **version**，CLI 会把它当成新迁移并尝试重新应用。
而部分迁移在重放时是破坏性的（例如 `00040_ledger_perf_lockdown.sql` 里有
`drop table if exists trade cascade`），盲目重放会**丢数据**。

安全做法是改写已记录的 version，而不是重跑任何迁移：

```sql
-- 在事务中，把每个旧 version 字符串映射为新的
update supabase_migrations.schema_migrations set version = '00010' where version = '0001';
...
```

本地 / CI 数据库是一次性的 —— 直接 `supabase db reset` 即可。

---

## 行级安全（RLS）模型与约定

pg-outcry 如何保护表访问、为什么 RLS 要在迁移里**声明式**写好,以及那个堵住"自动 RLS"反复踩坑的 CI 守卫。

### 模型:默认拒绝,经 API 面访问

用户从不直接碰底表。客户端的一切都经过:

- **`SECURITY DEFINER` RPC** —— `place_order`、`request_withdrawal_to`、`stake`、`my_deposit_address` 等。
  它们以属主身份运行、自行鉴权(`current_app_entity_id()`),绕过 RLS。
- **一小撮授予 `anon` / `authenticated` 的视图**。

`00040_ledger_perf_lockdown.sql` 从 `anon`/`authenticated` 收回所有函数的 `EXECUTE`,只重新授予白名单 RPC。表遵循同样
精神:**RLS 开、默认拒绝**,仅在客户端确实需要读时才放开。

### 三类表

| 类别 | 例子 | 策略 |
|---|---|---|
| **公开参考 / 参数** | `instrument`、`currency`、`fee`、`price_level`、`stake_pool`、`perp_market`、`margin_config`、`stake_config`、`referral_config`、`instrument_risk`、`withdrawal_limit` | `SELECT … USING (true)` 给 `anon, authenticated` —— 非敏感的市场/交易所参数 |
| **每用户数据** | `currency_account`、`trade_order`、`wallet_request`、`watched_address`、`withdrawal_address`、`user_chain_wallet`、`stake_position`、`perp_position`、`margin_loan`、`api_key`、`chain_deposit`、`perp_event`、`margin_liquidation` | `SELECT … USING (app_entity_id = current_app_entity_id())`(或等价归属判断,如 `chain_deposit` 用 memo `'oc' || current_app_entity_id()`) |
| **资金 / 账本 / 引擎内部** | `transfer`、`*_ledger_entry_*`、`book_order`、`admin_audit_log`、`chain_cursor`、`chain_balance_cursor`、`trade` 分区、`stop_order`、`instrument_account_transfer` | **RLS 开、无策略 = 默认拒绝。** 正确且有意 —— 客户端只经 `SECURITY DEFINER` RPC/视图访问。**不要**加策略。 |

### 关键:`security_invoker` 视图 vs `SECURITY DEFINER` 视图

- **`SECURITY DEFINER`** 视图(Postgres 默认)以属主身份运行,**绕过**底表 RLS。`margin_terms`、
  `perp_markets`、`stake_pools`、`referral_summary`、`reconciliation_report` 都是 definer 视图 —— 读
  config/内部表无需策略。
- **`security_invoker = on`** 视图以**调用者**身份运行,底表 RLS **生效**。所有每用户视图都是 invoker:
  `cash_balances`、`my_stakes`、`my_perp`、`my_margin`、`my_chain_deposits`、`my_deposit_addresses`、
  `withdrawal_addresses`、`open_orders`、`order_book_l2`、`trade_history`、`instrument_balances`、`api_keys`。

> **一个 invoker 视图读到「RLS 开但零策略」的表,会静默返回空。**

### 那个坑:Supabase 会自动开 RLS

Supabase 的安全顾问会**带外**(不经我们的迁移)给 public 表开 RLS。一旦命中某张 invoker 视图用到、而我们
又没写策略的表,线上功能就坏,而 CI(全新本地库,从没被自动开过 RLS)还是绿的。我们在 `stake_pool`、
`perp_market`、`chain_deposit` 上踩过。

**规则:RLS 声明式。** 在建表的迁移里,既 `ENABLE ROW LEVEL SECURITY`,**又**加上策略(或对内部表有意保持
默认拒绝)。这样全新库 == 线上,Supabase 自动开关也改变不了什么。

```sql
alter table stake_pool enable row level security;          -- 主动做线上反正也会做的事
create policy read_stake_pool on stake_pool
  for select to anon, authenticated using (true);          -- …并补上应有的策略
```

### CI 守卫

`scripts/check-rls-policies.sh`(在 `ci.yml` 里紧跟迁移应用后运行)遍历每个授予 `anon`/`authenticated` 的
`security_invoker` 视图,经 `pg_depend`/`pg_rewrite` 解析底表,若有底表是「RLS 开但无策略」就**失败**,并打印
`视图 -> 表`。它会忽略那些默认拒绝的内部表(没有 invoker 视图读它们),所以不会逼你加错策略。任何地方都能跑:

```bash
PGURL=postgresql://user:pass@host:5432/db bash scripts/check-rls-policies.sh
```

### 新增表/视图时的清单

1. 建一张客户端要读的表?在同一迁移里 `ENABLE ROW LEVEL SECURITY` + 加正确策略(公开只读 或 自有行)。
   内部/账本表?开 RLS、不加策略。
2. 要一个每用户视图?设 `security_invoker = on`,并确保每张底表都有自有行(或公开只读)策略。要安全地暴露
   聚合/内部数据?用 `SECURITY DEFINER` 视图。
3. 编号 `> 9900`,这样 `9900_lockdown` 在你的授予之前已运行。
4. 本地跑 `bash scripts/check-rls-policies.sh` —— 绿了再推。

### 自建部署完全复用

这里的一切都是 `supabase db reset`(或 `supabase db push`)应用的纯 SQL 迁移,所以自建 Postgres 得到**完全
相同**的 RLS 姿态,没有任何仅限托管的步骤。CI 守卫对任意 `PGURL` 都能跑。唯一仅限托管的行为(Supabase 自动
开 RLS)正是声明式做法所中和掉的,因此本地、CI、线上始终一致。见 [DEPLOY.md](./DEPLOY.zh-CN.md)。

#### 近期新增的表

| 表 | 分类 | 策略 |
|---|---|---|
| `candle_1m` | 公开行情数据 | 对 `anon, authenticated` 开放 `select`，条件 `true` |
| `reconcile_alert` | 运营证据 | 对 `authenticated` 开放 `select`（写入仅 service_role） |
| `admin_config` | 运营配置 | 对 `authenticated` 开放 `select`；写入走 `admin_set_open_access()` |

---

[← 返回文档](./README.md) · [← 项目 README](../README.zh-CN.md)
