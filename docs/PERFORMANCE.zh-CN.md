[English](./PERFORMANCE.md) · **中文**

# 性能与扩展计划

六项指令的状态。✅ = 已实现并验证，◐ = 部分完成，
⬜ = 已设计，可按需实现。

| # | 指令 | 状态 |
|---|-----------|--------|
| 1 | 按交易品种分片 | ◐ 逻辑隔离已完成；单库对 trade_order 的分区方案被否决（会破坏私有数据流）；推荐采用多节点路由 |
| 2 | 热数据驻留内存 | ✅ `9730` book_order + price_level 改为 UNLOGGED + rebuild_book() |
| 3 | 冷数据分区 | ✅ `9640` 对 trade 及两个账本按月做 RANGE 分区 |
| 4 | 异步行情数据 | ✅ `9720` 通过 `realtime.send` 实现合并的 L2 + 成交带；100ms 行情推送 |
| 5 | 仅追加账本 | ✅ `9630` 触发器；对账报告 |
| 6 | 降低 WAL 压力 | ✅ `9710` replica identity + `9720` 将 price_level/trade 从 Postgres Changes 中移除 |

---

## 1. 按交易品种分片

**已完成：** 撮合已经通过 `pg_advisory_xact_lock(instrument_id)`（`9100`/`9500`）按*每个标的*串行化。不同交易品种之间永不互相阻塞——它们在单个数据库上完全并发运行。这就是对*临界区*的逻辑分片。

**单库内按标的对 `trade_order` 分区 —— 已否决（会使系统退化）。**
经过深入调研；三个棘手问题使其得不偿失：
1. **破坏私有数据流。** `trade_order` 通过 Realtime Postgres Changes
   （按订阅者做 RLS）被消费，用于按用户的订单/成交流。Postgres Changes 不会
   从分区表投递数据，因此分区会迫使私有数据流重新架构到 Broadcast + `realtime.messages` RLS
   之上——从而失去我们所依赖的自动 RLS。
2. **使引擎与复合外键分叉。** 主键 → `(instrument_id, id)`；5 个入向外键
   （`book_order`、`stop_order`、`trade`×3）变为复合外键，需要在
   `book_order`/`stop_order` 上加上 `instrument_id`，并改动引擎的 INSERT。
3. **使点查退化。** 引擎按 `id`/`pub_id` 查找订单而不带
   标的过滤条件（例如 `cancel_trade_order`），这将扫描每一个分区。

按标的的并发已经由咨询锁提供，因此吞吐量的提升空间很小。**实现真正水平扩展的推荐路径：多节点标的路由**——每个
分片是它自己的 Supabase 项目，运行这套完全相同的迁移集并拥有一组互不相交的
标的；一个无状态路由器将 `symbol → shard` 映射。CEX 中不存在跨标的事务，
因此这种分片无需触碰 schema 即可干净地完成，再由一个共享的身份/钱包平面
持有系统的记录源（system-of-record）。（`price_level` *确实*可以按 `instrument_id`
轻松分区，但它现在是一张很小的 UNLOGGED 表，因此没有意义。）

**下一步（多节点）：将标的路由到独立的 Supabase 项目。**
每个项目都是一个自包含的纯 PG 引擎，拥有一组互不相交的标的。一个轻量的无状态路由器（或置于 `pg_cat`/外部表之前的 PostgREST）将 `symbol → project` 映射。CEX 中不存在跨标的事务（一笔订单只触及一个订单簿），因此这种分片可以干净地完成。跨项目方面：可使用一个共享的身份/钱包项目，或在各分片间复制余额而以钱包作为系统的记录源。

## 2. 热数据驻留内存 —— ✅ 已完成 `9730`

实时订单簿（`book_order`、`price_level`）是纯派生状态，可从
持久化的 `trade_order` 行重建。两者现在均为 **UNLOGGED**：写入跳过 WAL（在撮合热路径上
节省巨大）且数据驻留内存。两者都不再通过 Realtime 面向客户端（L2 是从
`price_level` 的*读取*广播出去的；私有数据流使用 `trade_order`），因此在它们上面
失去逻辑复制是可以接受的。`book_order` 最先从 Postgres Changes publication 中移除。`rebuild_book()`
会在非正常关机后从未成交订单重建两者（UNLOGGED 表在崩溃后恢复时为空）——在
启动时运行一次即可。已验证：结算仍然通过；重建能精确恢复订单簿。

## 3. 冷数据分区 —— ✅ 已完成 `9640`

`trade`、`transfer_ledger_entry`、`instrument_account_ledger_entry`（0 个入向外键，
仅追加，无界增长）被重建为**按月对 `created_at` 做 RANGE 分区**，主键为
`(id, created_at)`，包含上一个月到 +14 个月的分区，再加一个 DEFAULT 兜底分区，使
插入永不失败。`create_monthly_partitions()` 辅助函数 + `roll_partitions()` 通过 `pg_cron`
（每月）定时滚动未来的月份。引擎的 `INSERT` 透明路由。
已验证：结算（`smoke-stage2`）+ 对账（`smoke-stage7`）在分区表上均通过。
旧分区可以 `DETACH` 以进行压缩/导出。

**Realtime 注意事项（重要）：** Postgres Changes **不会**从分区表
投递数据（即便设置了 `publish_via_partition_root`）。因此 `trade` 已从 Postgres
Changes 中移除，其成交带改用 Broadcast——见 #4。

## 4. 异步行情数据 —— ✅ 已完成 `9720`

两条公开数据流均从 Postgres Changes 迁移到主题 `md:<symbol>` 上的 **Broadcast**：
- **L2 订单簿**（`event:'l2'`，已合并）：`price_level` 上的 AFTER 触发器在
  `md_dirty` 中标记该标的（开销低，处于撮合事务内）。`broadcast_md()` 为每个脏订单簿
  构建一份 top-50 的 L2 快照并通过 `realtime.send()` 发送，然后清除标志
  （`FOR UPDATE SKIP LOCKED`，使重叠的行情推送永不重复发送）。由
  `examples/md-ticker.mjs` 每 **100ms** 调用一次（逻辑为纯 PG；只有定时器在外部，
  因为 pg_cron 无法达到亚秒级——可注册一个 1s 的 pg_cron 兜底）。
- **成交带**（`event:'trade'`）：`trade` 上的 AFTER INSERT 触发器广播每一笔
  成交。无需行情推送器。

`price_level` 和 `trade` 已从 Postgres Changes publication 中移除，因此
撮合关键路径不再为行情数据支付逐行的逻辑解码 + FULL replica identity 开销——
消息速率现在受行情推送间隔约束。客户端订阅
`md:<symbol>` 频道（`private:false`，无需鉴权）。已由 `smoke-realtime`/`smoke-marketdata` 验证。

> Realtime 预热：在 `supabase db reset` 之后，realtime 容器需要数秒
> 才能让广播订阅开始投递；脚本会等待约 3.5s。

## 5. 仅追加账本 —— ✅ 已完成

`9630_reconciliation.sql`：`transfer_ledger_entry` 和 `instrument_account_ledger_entry` 上的 `BEFORE UPDATE OR DELETE` 触发器会抛出 `append_only_ledger`。引擎只会 INSERT 账目，因此这对正常运行不可见，并保证余额始终可重新派生。`reconcile()` 审计 5 项核心账本不变量（现金==账本、复式记账平衡、预留合理、已批准钱包有转账、发行量守恒）。`custody_reconcile()` 额外检查用户资金是否有链上充值证据，以及钱包充值申请是否已禁用。已由 `scripts/smoke-stage7.sh` 验证。

## 6. 降低 WAL 压力 —— ✅（第一轮）

**已完成 `9710`：** `trade`、`trade_order`、`book_order`、`wallet_request` 从 REPLICA IDENTITY FULL → DEFAULT（主键）。FULL 会在每次 UPDATE/DELETE 时把整行旧数据写入 WAL；DEFAULT 只写主键，而 Postgres Changes 仍能投递 NEW 元组。已验证 Realtime 不受影响（`smoke-realtime`、`smoke-stage6`）。`price_level` 保留 FULL，以便 L2 DELETE 事件携带价格/方向。

**已完成 `9720`：** `price_level` 和 `trade` 已从 Postgres Changes publication 中移除
（行情数据现在走 Broadcast），消除了它们在热路径上逐行的逻辑解码 WAL。

**进一步降低（配置项 / 可按需提供）：**
- `wal_compression = on`（减少整页写入的 WAL）。
- `book_order` 现在可以改为 UNLOGGED（不面向客户端，可从 `trade_order` 重建）。
- 调整检查点频率 / `max_wal_size`（由 Supabase 托管；可能需要项目级设置）。
- 避免冗余的 `price_level` UPDATE（跳过无变化的数量写入）。

---

# 突破纯 PG 极限（基准、插件、C 扩展）

## 基线与剖析
- **吞吐量**：1000 对交叉的撮合+结算顺序执行（单连接）≈ **4.5s → ~220 撮合/秒**（~440 下单/秒）。跨标的负载可通过按标的的咨询锁进一步扩展。
- 使用 `pg_stat_statements`（`track=all`）**剖析**。热路径：
  - `create_trade` ≈ **2.4ms/笔** —— 由 4× `process_transfer` 复式记账结算主导。这是不可削减的核心成本。
  - **逐笔止损单扫描**（`process_crossing_stop_orders` + 止损连接）在**每一笔成交时对所有未成交订单执行一次 Seq Scan**（剖析显示 "Rows Removed by Filter: 2602"），即便没有任何止损单——呈 O(n) 增长。
  - Realtime 的 WAL 逻辑解码也作为后台负载出现（通过将行情数据移出 Postgres Changes 已将其最小化）。

## 优化：部分索引（`9750`）
`trade_order_stops_idx`——一个仅覆盖 STOPLOSS/STOPLIMIT 行的部分索引——将
逐笔止损探测从全表 Seq Scan 变为瞬时的 0 行索引扫描（计划已验证）。
体积极小（止损单罕见）；其收益随 `trade_order` 规模增长，防止随历史累积而使
每笔成交呈 O(n) 退化。

## 已测试的插件（78 个可用中的）
- **pg_stat_statements** —— 剖析撮合热路径（上文已用）。
- **pg_prewarm / pg_buffercache** —— 预热并检视热门订单簿/订单表的缓存。
- **hypopg** —— 在落地真实索引前做假设性索引的 what-if 分析。
- **pgstattuple** —— 对仅追加账本分区做膨胀检查。
- **pg_cron** —— 分区滚动 + 行情兜底推送器（已使用）。
- 还可备用：`plpgsql_check`、`pgmq`、`vector`、`pgaudit`、`pg_net`、`pg_partman`、`pg_repack`。

## 自定义 C 扩展 —— `oc_fastmath`（`ext/oc_fastmath/`）
原生 C 在热标量数学上胜过 PL/pgSQL。`oc_banker_round(float8,int)`（四舍六入五成双）：
- **200 万次调用：0.87s（C）vs 4.54s（PL/pgSQL）≈ 快 5.2×。**

在此处构建并非易事，因为该数据库是 **基于 nix 构建、运行在 Alpine 上的 PG 17.6**：
- 服务器头文件位于 nix store（`pg_config` 的路径被剥离）—— 需针对
  `/nix/store/*-postgresql-17.6/include/server` 编译；
- `pkglibdir` 是**只读的** nix store → 将 `.so` 安装到 **PGDATA**（持久、
  可写），并按绝对路径加载；
- 容器自带的 **`nix`** 可按需提供 ABI 匹配的 `gcc`；
- `postgres` 角色**不是** superuser → 需以 **`supabase_admin`** 身份创建 C 函数。

`ext/oc_fastmath/build.sh` 会幂等地完成以上全部；在 `supabase start`
之后运行（在 `supabase db reset` 之后重新运行其中的 SQL 部分——`.so` 会持久保留在 PGDATA 中）。

### oc_banker_round_numeric —— 引擎热门辅助函数的原生即插即用替代
`banker_round(numeric,int)`（四舍六入五成双）是结算路径上唯一真正受 CPU 限制的
辅助函数。通过服务器 numeric API 用 C 重新实现，与 PL/pgSQL 版本**逐位完全一致**
（在 20,012 个随机 + 边界用例上 0 处不符），且在**隔离场景下快约 2.8×**
（200 万次调用：C 1.46s vs PL/pgSQL 4.07s）。`build.sh` 默认将引擎的
`banker_round` 替换为 C 版本（以 supabase_admin 身份 DROP+CREATE；PL/pgSQL 函数体
按名称解析它）。已验证：在热路径采用 C 取整后，结算 + 全部 5 项对账不变量仍然通过。

### 热点图谱与诚实的极限
剖析了每个热点并按性质分类（原生代码只对受 CPU 限制的工作有帮助；
PL/pgSQL 对受 SQL 限制的工作已做计划缓存）：

| 热点 | 性质 | 优化 |
|----------|--------|--------------|
| `create_trade` 结算（4× `process_transfer`，~2.4ms/笔） | **I/O**（堆插入 + WAL + 索引） | 结构性：UNLOGGED 订单簿、分区账本、降低 WAL |
| `banker_round`（numeric，五成双） | **CPU** | **原生 C，2.8×**（`oc_fastmath`） |
| 逐笔止损单扫描 | CPU+I/O（原为 O(n) 顺序扫描） | 部分索引 `9750` → O(log n) |
| `price_level` 更新 | I/O | UNLOGGED（`9730`） |
| `uuid_generate_v4` ×~8/笔 | CPU（极小） | 每次 ~1.3µs ≈ 一笔成交的 0.2% —— **不值得改动** |
| 行情数据扇出 | I/O（逻辑解码） | 移出 Postgres Changes → Broadcast |

**结论 / 极限：** 端到端的撮合吞吐量是 **I/O 受限的**——由
复式记账结算的堆插入、索引维护和 WAL 主导（每笔成交 ~8 次插入 + 4 次更新 +
查找）。原生（C/Rust）插件在受 CPU 限制的辅助函数上带来很大的*隔离*提速
（banker_round 2.8×），但无法撼动端到端吞吐量，因为成本在
存储执行器，而非 PL/pgSQL 解释器。要突破这道底线，需要**结构性**
改动（每笔成交更少的行、批处理）或**水平**扩展（多节点标的路由）——
而非更多原生标量代码。受 CPU 限制的热点现在已原生化；受 I/O 限制的则通过
结构性手段解决；这就是单节点上纯 PG 的极限。

### 批量账本写入（`9760`）
`create_transfer` 现在以单条 2 行 INSERT 写入其 DEBIT+CREDIT 账目，而非
两条单行 INSERT（每笔 FX 成交：8→4 条账本插入语句）。行相同、语义完全相同——
已由结算 + 全部 5 项对账不变量及完整的 11 流程套件验证。

**诚实的上限：** 批处理削减的是每*语句*的执行器开销，**而非**每*行*的 I/O——
同样的 8 行账目仍要做堆插入、建索引和 WAL 记录，而这才是主导
成本。因此收益受语句开销限制（个位数 %），在本机上处于
基准噪声范围内。要削减行 I/O 本身，唯一办法是发出**每笔成交更少的
行**——即消除 MASTER 中转腿，使每种资产在买方↔卖方之间直接划转
（4 次转账/8 行账目 → 2 次转账/4 行账目，约使结算 WAL 减半）。
这会改变结算模型（MASTER 不再作为资产腿的清算对手方；
手续费将变为显式的 CHARGE 转账），因此它被作为一个深思熟虑的设计决策推迟，
而不是悄无声息地施加于资金处理代码。
