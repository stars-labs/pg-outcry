[English](./DERIVATIVES.md) · **中文**

# 纯 Postgres 的衍生品与质押 —— 可行性 + 计划

保证金 / 合约 / 质押能用纯 PG 做吗？有哪些扩展能帮上忙？
[← 文档](./README.md) · [← 横向对比](./COMPARISON.zh-CN.md)

> **先说结论（诚实）：** [peatio](https://github.com/openware/peatio)、
> [OpenCEX](https://github.com/Polygant/OpenCEX)、[OPEX](https://github.com/opexdev/core) 三者的**开源版**
> 都没有实现这些 —— 它们是现货交易所。peatio 的保证金/合约/P2P 只存在于 Openware 的*商业* OpenDAX；
> OpenCEX/OPEX 根本不带。所以没有可抄的开源参考 —— 下面是把标准交易所架构映射到纯 PG 上。

## 结论

三者都能用纯 PostgreSQL 完成，**只需 `pg_cron` + `pg_net`**（已在用）—— **无需任何新的定制扩展**。
工作量：**质押（小） < 现货保证金（中） < 永续合约（大）**。唯一天然外部的依赖是**价格预言机**
（清算与资金费用的 index/mark 价），其获取方式与链上充值相同。真正的成本是**风险面**
（清算、资金费用、保险基金），而不是数据库。

## 扩展映射（基于实际 Supabase 镜像）

| 扩展 | 作用 | 本镜像状态 |
|---|---|---|
| **pg_cron** | 计息 / 资金费用 / 清算 / 解质押 的定时器 | ✅ 已装 |
| **pg_net** / **http** | 外部 index/预言机 价格拉取 | ✅ 已装 |
| **pgmq** | 持久队列：解质押、清算、资金费用、提现（替代手写 `SKIP LOCKED`） | ✅ 可用 —— **质押解锁已在用** |
| **pg_partman** | 自动分区时间序列（资金费用流水、mark 价历史） | ✅ 可用 |
| **pgsodium** | 库内 ed25519 签名 → **Solana/Sui** 提现/质押交易原生签名 | ✅ 可用 |
| **supabase_vault** | 若库内签名，加密存储热私钥 | ✅ 已装 |
| **wrappers**（FDW） | 把外部价格 API / 交易所建模为外表（预言机） | ✅ 可用 |
| **plpgsql_check** · **pgtap** | 静态检查 + 单测庞大的风险引擎 | ✅ 可用 |
| **pgaudit** | 面向受监管场景的合规级审计日志 | ✅ 可用 |
| _TimescaleDB / toolkit_ | hypertable + 连续聚合 → 服务端 OHLCV、mark/资金费用 序列 | ❌ **镜像中没有**（仅自建） |
| _plv8 / plpython3u_ | 库内 JS/Python（如 secp256k1 库） | ❌ 不可用 |

**签名要点：** **ed25519 链（Solana、Sui）**可用 `pgsodium` 在库内签名（私钥放 `supabase_vault`）。
**secp256k1 链（BTC、所有 EVM、Tron）**没有现成扩展 → 外部签名器（当前设计）或自建 C 扩展
（编译 `libsecp256k1`，与 `oc_fastmath` 同套路）。

## 1. 质押 —— ✅ 已交付（迁移 `9930`）

质押某币种、按 APR 通过「每单位累积奖励」累加器赚取奖励（MasterChef 模式，每次交互时惰性结算 —— 无需计息 cron），
解质押带解锁期。

- 资金流动复用 `process_transfer`，因此对账成立：**质押** = `WITHDRAWAL` user→MASTER（锁本金）、
  **奖励** = `DEPOSIT` MASTER→user（发行，类似水龙头）、**解锁** = 延迟后 `DEPOSIT` MASTER→user。
- **pgmq** 持有解质押队列（`pgmq.send(..., delay)`）；**pg_cron** 任务 `process_unbonding()`
  消费到期消息并返还本金。
- RPC：`stake` / `unstake` / `claim_stake_rewards`（认证）；视图 `my_stakes`（实时待领奖励）+ `stake_pools`。
  已在 `scripts/smoke-features.mjs` 验证（质押 → 10% APR 约 10 奖励 → 解质押 → 解锁返还 → **reconcile() 全 PASS**）。

## 2. 现货保证金 —— ✅ 已交付（迁移 `9940`）

跨保证金，以 EUR 计价（用最新成交价）。`borrow` 抵押借贷（由 house 从 MASTER 出借），带**最大杠杆上限**
（总负债 ≤ 权益·(L−1)）；利息惰性计提；`repay`；以及一个 `pg_cron` **清算监控**
（`check_margin_liquidations`）按当前价标记每个账户，当权益 ≤ 负债·维持率时**清算**。所有资金流动经
`process_transfer`（借 = DEPOSIT MASTER→user，还/清算 = user→MASTER），因此对账成立。RPC：`borrow` /
`repay` / `my_margin_health`（认证）；视图 `my_margin` + `margin_terms`。已在 `scripts/smoke-features.mjs`
验证（2 倍借贷 → 超杠杆被拒 → 还款 → 利息驱动清算并没收抵押 → **reconcile() 全 PASS**）。

**相比生产的简化：** 清算是按标记价的强制结算（没收抵押、清零负债、亏空由 house 承担），而非把市价单走订单簿；
无部分清算 / 保险基金 / ADL。无需新扩展。

## 3. 永续合约 —— ✅ 已交付（迁移 `9950`）

基于仓位的线性永续（`BTC-PERP`，以 EUR 计保证金）：
- **mark 价**由预言机（`update_perp_mark`，`pg_cron`）从现货最新成交价设置 —— 也可外部覆盖 / 经 `pg_net` 接真实 index。
- **`open_perp` / `close_perp`** —— 缴纳保证金、按**最大杠杆上限**开有符号仓位；平仓实现 uPnL = size·(mark−entry)；
  payout = 保证金+盈亏（下限 0），全经 `process_transfer`。
- **资金费用**（`apply_perp_funding`，`pg_cron`）—— 费率为正时多头付空头（调整保证金 claim）。
- **清算**（`check_perp_liquidations`，`pg_cron`）—— 当权益 ≤ size·mark·维持率时没收保证金。
- 视图 `my_perp`（实时 uPnL/权益）+ `perp_markets`。已在 `scripts/smoke-features.mjs` 验证
  （5 倍开多 → mark→130 uPnL 30 → 平仓 +30 → 跌价清算 → 资金费用 → **reconcile() 全 PASS**）。

**相比生产的简化：** 每市场单个净仓、仅从空仓开；house（MASTER）作对手方/保险（盈亏不在多空间净额）；
清算按标记价没收保证金（无部分平仓 / 订单簿路由 / ADL）。规模化时用 **pg_partman** 存资金费用/mark 价历史。

## 路线图

`质押 ✅ → 现货保证金 ✅ → 永续合约 ✅`。每一项都可选且带真实金融风险 —— 它们处于受监管的一端
（[WHY.zh-CN.md §9](./WHY.zh-CN.md#9-什么情况下别用它)）；pg-outcry 的核心仍是正确性优先的**现货**交易所。
