[English](./RLS.md) · **中文**

# 行级安全（RLS）模型与约定

pg-outcry 如何保护表访问、为什么 RLS 要在迁移里**声明式**写好,以及那个堵住"自动 RLS"反复踩坑的 CI 守卫。
[← 文档](./README.md) · [← 开发](./DEVELOPMENT.zh-CN.md)

## 模型:默认拒绝,经 API 面访问

用户从不直接碰底表。客户端的一切都经过:

- **`SECURITY DEFINER` RPC** —— `place_order`、`request_withdrawal_to`、`stake`、`my_deposit_address` 等。
  它们以属主身份运行、自行鉴权(`current_app_entity_id()`),绕过 RLS。
- **一小撮授予 `anon` / `authenticated` 的视图**。

`9900_lockdown.sql` 从 `anon`/`authenticated` 收回所有函数的 `EXECUTE`,只重新授予白名单 RPC。表遵循同样
精神:**RLS 开、默认拒绝**,仅在客户端确实需要读时才放开。

## 三类表

| 类别 | 例子 | 策略 |
|---|---|---|
| **公开参考 / 参数** | `instrument`、`currency`、`fee`、`price_level`、`stake_pool`、`perp_market`、`margin_config`、`stake_config`、`referral_config`、`instrument_risk`、`withdrawal_limit` | `SELECT … USING (true)` 给 `anon, authenticated` —— 非敏感的市场/交易所参数 |
| **每用户数据** | `currency_account`、`trade_order`、`wallet_request`、`watched_address`、`withdrawal_address`、`user_chain_wallet`、`stake_position`、`perp_position`、`margin_loan`、`api_key`、`chain_deposit`、`perp_event`、`margin_liquidation` | `SELECT … USING (app_entity_id = current_app_entity_id())`(或等价归属判断,如 `chain_deposit` 用 memo `'oc' || current_app_entity_id()`) |
| **资金 / 账本 / 引擎内部** | `transfer`、`*_ledger_entry_*`、`book_order`、`admin_audit_log`、`chain_cursor`、`chain_balance_cursor`、`trade` 分区、`stop_order`、`instrument_account_transfer` | **RLS 开、无策略 = 默认拒绝。** 正确且有意 —— 客户端只经 `SECURITY DEFINER` RPC/视图访问。**不要**加策略。 |

## 关键:`security_invoker` 视图 vs `SECURITY DEFINER` 视图

- **`SECURITY DEFINER`** 视图(Postgres 默认)以属主身份运行,**绕过**底表 RLS。`margin_terms`、
  `perp_markets`、`stake_pools`、`referral_summary`、`reconciliation_report` 都是 definer 视图 —— 读
  config/内部表无需策略。
- **`security_invoker = on`** 视图以**调用者**身份运行,底表 RLS **生效**。所有每用户视图都是 invoker:
  `cash_balances`、`my_stakes`、`my_perp`、`my_margin`、`my_chain_deposits`、`my_deposit_addresses`、
  `withdrawal_addresses`、`open_orders`、`order_book_l2`、`trade_history`、`instrument_balances`、`api_keys`。

> **一个 invoker 视图读到「RLS 开但零策略」的表,会静默返回空。**

## 那个坑:Supabase 会自动开 RLS

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

## CI 守卫

`scripts/check-rls-policies.sh`(在 `ci.yml` 里紧跟迁移应用后运行)遍历每个授予 `anon`/`authenticated` 的
`security_invoker` 视图,经 `pg_depend`/`pg_rewrite` 解析底表,若有底表是「RLS 开但无策略」就**失败**,并打印
`视图 -> 表`。它会忽略那些默认拒绝的内部表(没有 invoker 视图读它们),所以不会逼你加错策略。任何地方都能跑:

```bash
PGURL=postgresql://user:pass@host:5432/db bash scripts/check-rls-policies.sh
```

## 新增表/视图时的清单

1. 建一张客户端要读的表?在同一迁移里 `ENABLE ROW LEVEL SECURITY` + 加正确策略(公开只读 或 自有行)。
   内部/账本表?开 RLS、不加策略。
2. 要一个每用户视图?设 `security_invoker = on`,并确保每张底表都有自有行(或公开只读)策略。要安全地暴露
   聚合/内部数据?用 `SECURITY DEFINER` 视图。
3. 编号 `> 9900`,这样 `9900_lockdown` 在你的授予之前已运行。
4. 本地跑 `bash scripts/check-rls-policies.sh` —— 绿了再推。

## 自建部署完全复用

这里的一切都是 `supabase db reset`(或 `supabase db push`)应用的纯 SQL 迁移,所以自建 Postgres 得到**完全
相同**的 RLS 姿态,没有任何仅限托管的步骤。CI 守卫对任意 `PGURL` 都能跑。唯一仅限托管的行为(Supabase 自动
开 RLS)正是声明式做法所中和掉的,因此本地、CI、线上始终一致。见 [DEPLOY.md](./DEPLOY.zh-CN.md)。
