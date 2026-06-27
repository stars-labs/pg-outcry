[English](./COMPARISON.md) · **中文**

# pg-outcry 横向对比 —— 以及我们还缺什么

与三个成熟的开源交易所做功能对比，并给出诚实的差距分析。
[← 返回文档](./README.md) · [← README](../README.zh-CN.md)

这三个参照物都是完整的交易所**产品**（真实托管、KYC、法币）。pg-outcry 是一个正确性优先的**引擎**：
数据库本身就是交易所。因此差距分为两类截然不同的桶 ——（A）任何架构的交易所都要在边缘集成的外部组件，
（B）我们可以**用纯 SQL**补齐、同时保持「整个交易所跑在 Postgres 里」论点的功能。

## 功能矩阵

| 能力 | [peatio](https://github.com/openware/peatio)（+Barong/Finex） | [OpenCEX](https://github.com/Polygant/OpenCEX) | [OPEX](https://github.com/opexdev/core) | **pg-outcry** |
|---|---|---|---|---|
| 撮合引擎 | ✅ Ruby/Go | ✅ Python | ✅ Kotlin | ✅ **PL/pgSQL** |
| 双边记账账本 + 对账 | ✅ | ✅ | ✅（Accountant 服务） | ✅ **库内、ACID、同一事务** |
| 订单类型 | 限价/市价/止损 | 限价/市价 | 限价/市价 | ✅ 限价/市价/止损/止损限价 · GTC/IOC/FOK |
| 链上充提 | ✅ 热/温/冷 | ✅ BTC/ETH/BNB/TRX/USDT | ✅ Blockchain Gateway | 🧩 内部账本 + 人工审批（网关在外部） |
| KYC / 身份 | ✅ Barong | ✅ Sumsub | ✅ Keycloak | ❌（有意跳过） |
| KYT（交易筛查） | — | ✅ Scorechain | — | ❌ 外部供应商 |
| 2FA / MFA | ✅ 短信+TOTP | ✅ 短信 | ✅ Keycloak | ◐ Supabase MFA 可用 |
| 法币出入金 | ✅ | — | — | ❌ 外部（支付处理商） |
| 用户 API key（HMAC） | ✅ | ◐ | ✅ | 🔜 **建设中（纯 SQL）** |
| 推荐 / 返佣 | — | ✅ | ✅（Referral 服务） | 🔜 **建设中（纯 SQL）** |
| 提现白名单 + 限额 | ✅ | ✅ | ◐ | 🔜 **建设中（纯 SQL）** |
| 通知（邮件/短信） | ✅ | ✅ | ✅ | ◐ 经 Supabase 触发器 |
| 流动性 / 做市 | 经供应商 | ◐ | — | ❌ 仅演示灌单 |
| 公共 REST/WS 行情 API | ✅ v2 + WS + AMQP | ◐ | ✅ | ◐ PostgREST + Realtime（无 FIX） |
| 服务端 OHLCV/K线 | ✅ | ✅ | ✅ | ◐ 在 WASM 客户端计算 |
| 管理 / 后台 | ✅ | ✅ | ✅ | ✅ 审批/冻结/费率/风控/对账/审计 |
| 阶梯费率（按量） | ✅ | ◐ | ◐ | ◐ 固定 maker/taker |
| 杠杆 / 合约 / 质押 / P2P | 部分 | 部分 | — | ❌ 不在范围（现货） |
| **要运行的组件数** | Rails + Barong + Finex + RabbitMQ + DB | Django + Redis + RabbitMQ + 节点 | 约 11 个微服务 + Kafka + Redis + N×PG | ✅ **1 个 Postgres + Supabase** |

## 桶 A —— 外部集成（任何交易所都要在边缘接上）

这些**不是**纯 SQL 的弱点：peatio 跑独立的 Barong，OPEX 用 Blockchain Gateway + Keycloak，
OpenCEX 接 Twilio/Sumsub/Scorechain 的 key。pg-outcry 的赌注是：**账本在库内已经正确且持久**，
因此你在边缘接上这些组件，数据库始终是 system-of-record。

- **区块链托管** —— 把「引擎」和「产品」区分开的那一项。Postgres 无法监听链、也无法签名交易，所以这需要一个
  轻量的**库外钱包网关 worker**。账本那半已经做好（`request_deposit` / `approve_wallet_request` /
  冻结 + 结算）；网关负责：(1) 为每个用户派生充值地址，(2) 监听链、达到 N 个确认后调用入账路径（按 txid 幂等），
  (3) 对已批准的提现进行签名并广播。**用公开测试网**做一个真实、免费、无真实资金的演示 —— BTC signet/testnet、
  以太坊 **Sepolia**、TRON **Shasta**（都有水龙头）。这是路线图项；SQL 那半（地址表 + 幂等入账 RPC + 提现队列）
  可以先搭好，并配一个示例 worker。
- **KYC / KYT / 短信 / 法币** —— 都是供应商 API 集成。pg-outcry 暴露*挂载点*（账户状态、等级、限额），
  你把供应商接到状态字段上即可。KYC 本身**有意不做** —— 它面向的中小交易所起步阶段往往用不到供应商 KYC。

## 桶 B —— 可以用纯 SQL 补齐（最契合本项目的差距）

按杠杆排序。前三项**正在实现**：

1. **用户 API key（HMAC）** 🔜 —— 机器人/做市商需要程序化鉴权，而不是交互式 JWT。一张 `api_key` 表 +
   一个 key→短时 JWT 兑换 RPC（在 SQL 里签发），按 读/交易 限定范围。
2. **推荐 / 返佣** 🔜 —— OPEX 为此专门做了一个微服务；这用纯 SQL 极其简单：推荐码、一次性归因、按真实账本分录计提佣金。
3. **提现白名单 + 限额** 🔜 —— 地址白名单（带冷却期）+ 在 `request_withdrawal` 里按时间窗限额。目前只有人工审批。
4. **2FA/MFA** —— 接上 Supabase Auth TOTP + 前端注册流程。
5. **通知** —— 库内触发器 → `pg_net`/Edge Function，在成交、入金、提现状态变更时推送。
6. **服务端 OHLCV** —— 一个连续聚合 / 视图 + RPC，让非 WASM 客户端（移动端、TradingView）也能拿到 K 线。
   目前 K 线只存在于 WASM 客户端。
7. **按量阶梯费率与 maker 返佣** —— 扩展固定费率模型。
8. **文档化的公共 API** —— 为 PostgREST 接口出一份 OpenAPI + Realtime 频道规范，使其成为*真正的* API，而不只是「视图」。
   （FIX 仍不在范围。）

## 不在范围（现货参考交易所不必追）

杠杆 / 合约 / 衍生品、质押、P2P、借贷、FIX 协议 —— 都是不同的产品。见
[WHY.zh-CN.md › 什么情况下别用它](./WHY.zh-CN.md#9-什么情况下别用它)。

## 结论

最关键的差距是**区块链托管**，而它有意做成外部组件（在已正确的账本之上加一个网关 worker，可在公开测试网上演示）。
在纯 SQL 哲学之内，杠杆最高的补齐是 **API key、推荐返佣、提现安全**，它们强化而非稀释「整个交易所跑在 Postgres 里」
的故事 —— 也正是现在在建的内容。
