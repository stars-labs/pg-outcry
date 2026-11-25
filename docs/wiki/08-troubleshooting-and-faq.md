[English](./08-troubleshooting-and-faq.en.md) · **中文**

# 第 8 章：全量错误码速查词典、排障指南与术语总表（Troubleshooting & Glossary）

[← 上一章：后台审批与七重账本自证](./07-backoffice-and-reconciliation.md) · **第 8 章** · [返回 Wiki 总目录 →](./README.md)

---

在日常充值、交易或提币过程中，如果某项参数触发了风控护栏或余额不足，OUTCRY 终端右下角会弹出珊瑚红色的提示气泡（Toast），或者 API 返回包含错误码的 JSON。本章整理了**全站所有底层错误提示的中文逐条翻译、触发根因与 1 分钟解决步骤**，并附赠高频实战问答（FAQ）与加密货币交易所核心术语词典。

---

## 8.1 全站弹窗与 API 错误码速查词典

> *提示：网页终端会自动将底层错误码中的下划线 `_` 替换为空格展示（例如 `insufficient_available_balance` 在弹窗中显示为 `insufficient available balance`）。你可按 `Ctrl + F` 直接搜索弹窗关键词。*

### A. 登录鉴权与账户状态类

| 弹窗 / API 报错原文 | 中文含义与触发原因 | 1 分钟解决步骤 |
|---|---|---|
| `email + password required` | 点击登录或注册时邮箱或密码未填写完整。 | 补全邮箱与密码后重新点击按钮。 |
| `Invalid login credentials` | 登录模式下输入的邮箱不存在或密码错误（或误把新注册当成了登录）。 | 若尚未注册，请先点击底部 **`NO ACCOUNT? REGISTER →`** 切换为 `CREATE ACCOUNT →` 再提交。 |
| `User already registered` | 注册模式下输入的邮箱已存在。 | 点击底部 **`HAVE AN ACCOUNT? SIGN IN →`** 切换回登录模式即可。 |
| `not authenticated` / `no account` | 会话 JWT 已过期或未登录直接调用了受保护 RPC。 | 刷新页面重新登录；若为量化机器人，重新调用 `api_key_login` 续期 JWT。 |
| `account suspended` / `entity suspended` | 当前账户已被风控管理员临时冻结（Suspended），禁止下单与提币。 | 联系平台管理员排查风控原因，在后台 `Accounts` 模块执行 `Unsuspend` 解除冻结。 |

### B. 现货交易与事前风控类

| 弹窗 / API 报错原文 | 中文含义与触发原因 | 1 分钟解决步骤 |
|---|---|---|
| `insufficient funds` / `insufficient available balance` | 可用余额不足以支付当前买单成本或卖单数量。 | 1. 检查底部 **`OPEN ORDERS`** 是否有未成交老挂单占用了 `Reserved` 冻结额度，点 **`✕`** 撤单释放；<br/>2. 或前往 `Wallet → Deposit` 补充充值。 |
| `risk max order amount: X > Y` | 单笔下单数量 `X` 超过了该品种允许的单笔最大数量 `Y`（默认 `100`）。*注：高价品种下 `BUY MARKET` 发送的是报价币预算，也可能触碰此上限。* | 将大单拆分为多笔小单提交，或改用 **`LIMIT` + `IOC`** 按基础币数量精确报单；管理员亦可在后台 `Markets → Instrument Risk` 调高 `max amt`。 |
| `risk max order notional: X > Y` | 单笔订单名义总金额（`限价 × 数量 = X`）超过了单笔上限 `Y`（默认 `100,000 USDT`）。 | 调小单笔下单数量（例如在 `68,500 USDT` 价格下每笔不超过 `1.45 BTC`），分批执行。 |
| `risk price band: P beyond B pct band of reference R` | 防胖手指保护生效：你输入的限价 `P` 偏离当前参考价 `R` 超过了 `±B%`（默认 `±10%`）；或在开启价格带时直接发送了 `price=0` 的市价单。 | 1. 检查限价是否多敲/少敲了位数，将价格修正至参考价 `±10%` 区间内；<br/>2. 若想即时市价吃单，选 **`LIMIT`** + 填入略优于对手盘的保护价（如买单填 `参考价 × 1.01`）+ **`IOC`** 即可完美成交！ |
| `no asks to estimate market buy` | 当前卖盘（Asks）完全为空，无法估算市价买单所需的预算。 | 改用 **`LIMIT`**（限价单）挂出买单等待对手方成交。 |
| `instrument not enabled: <SYM>` | 该交易对已下架停盘（例如历史 `EUR` 计价交易对）。 | 切换至顶部品种栏当前激活的交易对（如 `BTC_USDT`）。 |

### C. 钱包充值与链上提币类

| 弹窗 / API 报错原文 | 中文含义与触发原因 | 1 分钟解决步骤 |
|---|---|---|
| `whitelist an address first` / `address not whitelisted or cooling` | 提币目标地址尚未加入白名单，或仍处于新地址安全冷却期内。 | 在 `Wallet → Withdraw` 下方先输入收款地址点击 **`WHITELIST`**，确认列表中状态显示为绿色 **`usable`** 后在下拉框选中该地址再提币。 |
| `withdrawal limit exceeded: A + B > L per 24h` | 过去 24 小时累计已提（含待审 `PENDING`）金额 `A` 加上本次申请金额 `B` 超过了滚动限额 `L`（默认 `5 BTC` 或 `50,000 USDT`）。 | 调小本次提币金额至剩余额度（$L - A$）以内，或等待 24 小时滚动窗口释放早期额度。 |
| `no currency account: <CUR>` | 你从未持有或入金过该币种（连对应币种账户都尚未初始化）。 | 先确认提币币种扣减的是哪个账户（`Debits your <CUR> balance`），确保该币种已有确认入账余额。 |
| `btc address not testnet: <ADDR>` | 提现 BTC 时误填了主网地址（如 `bc1q…`、`1…`、`3…`）或格式损坏的地址。 | 更换为合法的 **Bitcoin Testnet4** 地址（如 `tb1q…`、`tb1p…`、`m/n…`、`2…`）。 |
| `btc address bad checksum` / `mixed case` | Bech32 / Base58 提币地址存在拼写抄错或大小写混排，校验和未通过。 | 不要手敲地址！回到你的外部钱包使用一键复制重新粘贴，避免遗漏末尾字符。 |
| `btc insufficient hot wallet` | （后台签名阶段）平台链上热钱包已确认 UTXO 暂时不足（例如上一笔提币刚花掉大额 UTXO，找零输出还在等第 1 个区块确认）。 | 无需用户重提！等待链上找零确认后，下一轮 `pg_cron` 会自动完成签名与广播。 |

### D. 合约、杠杆、质押与邀请返佣类

| 弹窗 / API 报错原文 | 中文含义与触发原因 | 1 分钟解决步骤 |
|---|---|---|
| `position exists close first` | 在 `BTC-PERP` 上已有持仓，系统采用单市场净仓制，不支持直接叠加开新单。 | 先点击 `YOUR POSITIONS` 右侧的 **`close`** 平掉现有仓位，再按新目标仓位重新开仓。 |
| `insufficient margin: need X got Y` | 开立永续合约填写的保证金 `Y` 低于 `10×` 最大杠杆要求的最低初始保证金 `X`。 | 将 `margin` 调高至不少于 $|\text{Size}| \times \text{Mark} / 10$（建议留足缓冲以远离 `5%` 维持保证金强平线）。 |
| `no mark price` | 永续合约市场尚无最新标记价（现货盘还没有产生过参考成交）。 | 先在对应现货市场成交一笔或等待 `update_perp_mark` 同步参考价。 |
| `exceeds max leverage` | 全仓杠杆借币后总负债超过了净权益的 $(L_{\max}-1)$ 倍（默认 `2 × Equity`）。 | 减少借币数量，或先补充现货抵押资产。 |
| `insufficient staked` | 赎回质押输入的数量超过了当前质押在池中的本金。 | 直接点击仓位行的 **`unstake all`** 即可按准确本金全额发起解锁。 |

---

## 8.2 十二大高频实战问答（FAQ）

1. **Q：我已经在外部钱包发出了充值交易，为什么过去 1 分钟了右上角 `AVAILABLE` 还是 0？**
   - **A**：请打开 `Wallet → Deposit` 查看底部 `DETECTED DEPOSITS` 列表。如果状态显示橙色 **`pending…`**，说明系统已经检测到你的转账，正在等待区块链达到安全确认数（`BTC` 2 个区块、`Sepolia` 12 个、`Nile` 19 个、`Solana` 32 个）。一旦确认数达标，状态会自动变为绿色 **`credited`** 并秒级计入可用余额。
2. **Q：我的总资产（`Total`）没少，为什么下单时提示可用余额不足？**
   - **A**：检查右上角 `AVAILABLE` 旁边是否有橙色的 **`+xxx rsv`**！未成交的限价挂单（在 `OPEN ORDERS` 页签）和待审批的提币申请（在 `WALLET` 页签）都会冻结对应资金。点击挂单右侧的 **`✕`** 撤单即可立即释放。
3. **Q：提币申请提交后后悔了，或者填错了金额能取消吗？**
   - **A**：在提币尚处于 `PENDING`（管理员未点击 `APPROVE` 上链签名）阶段时，可联系管理员在后台 `Treasury` 点击 **`REJECT`** 驳回，冻结的资金会分毫不差退回你的可用余额；一旦上链广播（`BROADCAST` / `CONFIRMED`），区块链交易不可逆转。
4. **Q：提币 `0.25 BTC` 会扣多少提币手续费？实际到账多少？**
   - **A**：**`0` 提币扣费，100% 全额到账！** 在 OUTCRY 中，链上矿工费（Gas / Miner Fee）由平台热钱包金库全额承担，你申请提 `0.25 BTC`，收款地址就会精确收到 `0.25000000 BTC`。
5. **Q：为什么充值 ETH / TRX / SOL 后，增加的是 `EUR` 余额而不是 ETH？**
   - **A**：当前测试网配置将原生 Gas 币（Sepolia ETH、Nile TRX、Testnet SOL）统一映射到了演示法币计价户 `EUR`；如需直接交易 `BTC_USDT` 或开 `BTC-PERP` 合约，请充值 **`BTC`（Bitcoin · testnet4）** 与 **`USDT`（TRC-20 · Nile）**。
6. **Q：点击盘口上的价格有什么隐藏快捷功能？**
   - **A**：左键单击左侧 `ORDER BOOK · L2` 买盘或卖盘的任意一行，该档价格会直接填入右侧 `LIMIT PRICE` 输入框并自动重算 WASM 预估成本，省去手动输入五位数价格的麻烦。
7. **Q：我在 K 线图上画的支撑阻力线，刷新网页后会丢吗？**
   - **A**：**不会丢！** 所有画线按交易对（如 `oc_draw_BTC_USDT`）自动序列化保存在浏览器本地存储中，下次打开仍在原时间与价格锚点上；点击画线栏最底部的 **`⌫`** 可一键清空。
8. **Q：质押赚币（`Earn`）点击 `unstake all` 后，为什么本金没有马上回到 `AVAILABLE`？**
   - **A**：未领收益（`Pending reward`）会当场结清发放到 `AVAILABLE`，而质押本金遵循链上 PoS 质押惯例设有解锁期（默认 7 天，存于 `pgmq` 持久化队列 `stake_unbonding`），解锁期满后自动到账。
9. **Q：为什么我的账户是做市商账户时，提币瞬间就通过了，而且挂单也没了？**
   - **A**：这是 `00190` 原子自提机制的保护设计：当后台绑定的官方做市账户发起提币时，系统自动关停其做市报价、撤掉全部挂单以释放冻结库存，并免除人工审批直接进入自动签名打款队列，防止一边提款一边继续挂单导致库存错乱。
10. **Q：如何验证交易所此刻没有挪用客户资金或出现坏账？**
    - **A**：打开 `admin.html` 查看顶部 **`recon ALL PASS`** 及 `RECONCILIATION · INVARIANTS` 面板——7 项数学与链上托管背书检查全部 `PASS` 且 `FUNDING EXPOSURE = 0`，即代表每一分客户余额都有链上充值支撑且借贷分录完全平衡。
11. **Q：API Key 忘记保存 `secret` 了怎么办？**
    - **A**：出于零明文存储的安全原则，旧密钥无法找回 `secret`。请在 `API` 面板点击旧密钥右侧的 **`revoke`** 将其吊销，然后重新创建一个新 API Key 即可。
12. **Q：右上角连接状态从绿点 `live · realtime` 变成红点 `polling` 还能交易吗？**
    - **A**：**完全可以正常交易！** `polling` 仅代表 WebSocket 广播通道暂时断开，前端已自动降级为每 1.5 秒 HTTP 轮询拉取盘口；所有下单、撤单与提币走的是独立的 PostgREST HTTPS 事务接口，资金与撮合不受任何影响。

---

## 8.3 加密货币交易所核心术语词典（Glossary）

| 术语 | 简明权威解释 |
|---|---|
| **Maker（挂单方 / 做市方）** | 下达未立即成交的限价单、挂入订单簿为市场**提供流动性**的一方，通常享受更低费率。 |
| **Taker（吃单方）** | 下达市价单或穿过对手盘最优价的限价单、立即与已有挂单撮合从而**消耗流动性**的一方。 |
| **L2 Order Book（二级聚合盘口）** | 按每个价格档位汇总展示所有未成交买卖挂单总量的实时深度表。 |
| **Spread & bps（点差与基点）** | `卖一价 - 买一价` 为点差；`1 bp`（基点）等于万分之一（`0.01%`），点差越小说明市场交易摩擦越低。 |
| **VWAP（成交量加权平均价）** | 多笔或跨多档成交中，按各档成交数量加权计算出的真实平均成交单价。 |
| **GTC / IOC / FOK** | 三大标准订单生效时间指令：取消前一直排队（`GTC`）、能成多少立刻成多少其余撤单（`IOC`）、必须瞬间全额成交否则整单取消（`FOK`）。 |
| **Reserved（冻结资金）** | 因挂单排队或提币待审而被暂时锁定的资产：`Total = Available + Reserved`。 |
| **UTXO（未花费交易输出）** | 比特币网络的底层账本模型；每一笔收款都是一枚独立的「硬币碎片」，提币签名时挑选若干枚 UTXO 作为输入并找零回金库。 |
| **P2WPKH / Native SegWit** | 比特币原生隔离见证地址标准（测试网以 `tb1q` 开头，主网以 `bc1q` 开头），体积更小、链上手续费更低且杜绝交易延展性攻击。 |
| **Double-Entry Ledger（复式双边记账）** | 银行级会计准则：任何资金变动必须同时记录相等的借方与贷方分录，全库借贷代数和恒等于零。 |
| **RLS（行级安全策略）** | PostgreSQL 内核级访问控制机制，在数据库引擎最底层保证每个 JWT 会话永远只能看到属于自己的私有行。 |

---

**[← 返回第 7 章：后台审批与七重账本自证](./07-backoffice-and-reconciliation.md)** · **[🏠 回到 Wiki 总目录](./README.md)**
