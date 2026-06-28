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
| 链上充提 | ✅ 热/温/冷 | ✅ BTC/ETH/BNB/TRX/USDT | ✅ Blockchain Gateway | ◐ **充值在库内**（pg_cron+pg_net；Sepolia/Tron-Nile/Solana）+ **提现队列** → 外部签名器（[CHAIN.zh-CN.md](./CHAIN.zh-CN.md)） |
| KYC / 身份 | ✅ Barong | ✅ Sumsub | ✅ Keycloak | ❌（有意跳过） |
| KYT（交易筛查） | — | ✅ Scorechain | — | ❌ 外部供应商 |
| 2FA / MFA | ✅ 短信+TOTP | ✅ 短信 | ✅ Keycloak | ◐ Supabase MFA 可用 |
| 法币出入金 | ✅ | — | — | ❌ 外部（支付处理商） |
| 用户 API key（HMAC） | ✅ | ◐ | ✅ | ✅ **纯 SQL** |
| 推荐 / 返佣 | — | ✅ | ✅（Referral 服务） | ✅ **纯 SQL** |
| 提现白名单 + 限额 | ✅ | ✅ | ◐ | ✅ **纯 SQL** |
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

- **区块链托管** —— 把「引擎」和「产品」区分开的那一项。它分成两半：
  - **充值 —— 纯 Postgres 可做。** `pg_cron`（1.6，支持秒级）+ `pg_net`（库内对外 HTTP）可以**在库内**
    轮询链上 RPC/浏览器并入账：cron 任务用 `net.http_post` 调 JSON-RPC 节点（如 Sepolia 的
    `eth_getLogs` 监听 ERC-20 `Transfer`）或浏览器 API（BTC 用 Blockstream/mempool.space，TRON 用
    Tronscan）；下一拍把 `net._http_response` 当 `jsonb` 解析，对每笔**按 txid 幂等**、达到 **N 个确认**的
    新交易走入账路径。无需外部服务 —— 而 peatio/OpenCEX/OPEX 都跑一个独立网关。**用公开测试网**
    （BTC signet、以太坊 **Sepolia**、TRON **Shasta**）做免费、无真实资金的演示。
  - **提现 + HD 地址派生 —— 需要签名器。** `pgcrypto` 没有 secp256k1/keccak，所以构造并**签名**原始交易
    （以及派生每个用户的地址）无法用原生 SQL 完成。要么用一个签名**扩展**（C / `plpython3u` / `plv8`
    —— 留在库内，但热私钥进了数据库，是真实的安全权衡），要么用一个**极小的外部签名器**（仍由数据库决定
    *发什么*；广播只是 `pg_net`）。**已交付：** 纯 PG 充值监听（迁移 `9920` + 可选的
    Sepolia / Tron Nile / Solana 轮询器）**以及**数据库持有的提现发送队列（`9925`：`next_withdrawal_to_sign`
    用 `SKIP LOCKED` 认领、`mark_withdrawal_broadcast/confirmed`）+ 一个示例外部签名器。完整指南：**[CHAIN.zh-CN.md](./CHAIN.zh-CN.md)**。
- **KYC / KYT / 短信 / 法币** —— 都是供应商 API 集成。pg-outcry 暴露*挂载点*（账户状态、等级、限额），
  你把供应商接到状态字段上即可。KYC 本身**有意不做** —— 它面向的中小交易所起步阶段往往用不到供应商 KYC。

## 桶 B —— 可以用纯 SQL 补齐（最契合本项目的差距）

按杠杆排序。前三项**已交付（纯 SQL）** —— 见 [DEVELOPMENT.zh-CN.md](./DEVELOPMENT.zh-CN.md)：

1. **用户 API key（HMAC）** ✅ —— 机器人/做市商需要程序化鉴权，而不是交互式 JWT。一张 `api_key` 表 +
   一个 key→短时 JWT 兑换 RPC（在 SQL 里签发），按 读/交易 限定范围。
2. **推荐 / 返佣** ✅ —— OPEX 为此专门做了一个微服务；这用纯 SQL 极其简单：推荐码、一次性归因、按真实账本分录计提佣金。
3. **提现白名单 + 限额** ✅ —— 地址白名单（带冷却期）+ 在 `request_withdrawal` 里按时间窗限额。目前只有人工审批。
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
的故事 —— 也正是现已交付（并有 CI 冒烟覆盖）的内容。
