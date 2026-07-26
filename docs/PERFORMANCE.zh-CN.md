[English](./PERFORMANCE.md) · **中文**

# 性能与扩展计划

六项指令的状态。✅ = 已实现并验证，◐ = 部分完成，
⬜ = 已设计，可按需实现。

| # | 指令 | 状态 |
|---|-----------|--------|
| 1 | 按交易品种分片 | ◐ 逻辑隔离已完成；单库对 trade_order 的分区方案被否决（会破坏私有数据流）；推荐采用多节点路由 |
| 2 | 热数据驻留内存 | ✅ `00040_ledger_perf_lockdown` book_order + price_level 改为 UNLOGGED + rebuild_book() |
| 3 | 冷数据分区 | ✅ `00040_ledger_perf_lockdown` 对 trade 及两个账本按月做 RANGE 分区 |
| 4 | 异步行情数据 | ✅ `00040_ledger_perf_lockdown` 通过 `realtime.send` 实现合并的 L2 + 成交带；100ms 行情推送 |
| 5 | 仅追加账本 | ✅ `9630` 触发器；对账报告 |
| 6 | 降低 WAL 压力 | ✅ `9710` replica identity + `00040_ledger_perf_lockdown` 将 price_level/trade 从 Postgres Changes 中移除 |

---

### 1. 按交易品种分片

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

### 2. 热数据驻留内存 —— ✅ 已完成 `00040_ledger_perf_lockdown`

实时订单簿（`book_order`、`price_level`）是纯派生状态，可从
持久化的 `trade_order` 行重建。两者现在均为 **UNLOGGED**：写入跳过 WAL（在撮合热路径上
节省巨大）且数据驻留内存。两者都不再通过 Realtime 面向客户端（L2 是从
`price_level` 的*读取*广播出去的；私有数据流使用 `trade_order`），因此在它们上面
失去逻辑复制是可以接受的。`book_order` 最先从 Postgres Changes publication 中移除。`rebuild_book()`
会在非正常关机后从未成交订单重建两者（UNLOGGED 表在崩溃后恢复时为空）——在
启动时运行一次即可。已验证：结算仍然通过；重建能精确恢复订单簿。

### 3. 冷数据分区 —— ✅ 已完成 `00040_ledger_perf_lockdown`

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

### 4. 异步行情数据 —— ✅ 已完成 `00040_ledger_perf_lockdown`

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

### 5. 仅追加账本 —— ✅ 已完成

`00040_ledger_perf_lockdown.sql`：`transfer_ledger_entry` 和 `instrument_account_ledger_entry` 上的 `BEFORE UPDATE OR DELETE` 触发器会抛出 `append_only_ledger`。引擎只会 INSERT 账目，因此这对正常运行不可见，并保证余额始终可重新派生。`reconcile()` 审计 5 项核心账本不变量（现金==账本、复式记账平衡、预留合理、已批准钱包有转账、发行量守恒）。`custody_reconcile()` 额外检查用户资金是否有链上充值证据，以及钱包充值申请是否已禁用。已由 `scripts/smoke-stage7.sh` 验证。

### 6. 降低 WAL 压力 —— ✅（第一轮）

**已完成 `9710`：** `trade`、`trade_order`、`book_order`、`wallet_request` 从 REPLICA IDENTITY FULL → DEFAULT（主键）。FULL 会在每次 UPDATE/DELETE 时把整行旧数据写入 WAL；DEFAULT 只写主键，而 Postgres Changes 仍能投递 NEW 元组。已验证 Realtime 不受影响（`smoke-realtime`、`smoke-stage6`）。`price_level` 保留 FULL，以便 L2 DELETE 事件携带价格/方向。

**已完成 `00040_ledger_perf_lockdown`：** `price_level` 和 `trade` 已从 Postgres Changes publication 中移除
（行情数据现在走 Broadcast），消除了它们在热路径上逐行的逻辑解码 WAL。

**进一步降低（配置项 / 可按需提供）：**
- `wal_compression = on`（减少整页写入的 WAL）。
- `book_order` 现在可以改为 UNLOGGED（不面向客户端，可从 `trade_order` 重建）。
- 调整检查点频率 / `max_wal_size`（由 Supabase 托管；可能需要项目级设置）。
- 避免冗余的 `price_level` UPDATE（跳过无变化的数量写入）。

---

## 突破纯 PG 极限（基准、插件、C 扩展）

### 基线与剖析
- **吞吐量**：1000 对交叉的撮合+结算顺序执行（单连接）≈ **4.5s → ~220 撮合/秒**（~440 下单/秒）。跨标的负载可通过按标的的咨询锁进一步扩展。
- 使用 `pg_stat_statements`（`track=all`）**剖析**。热路径：
  - `create_trade` ≈ **2.4ms/笔** —— 由 4× `process_transfer` 复式记账结算主导。这是不可削减的核心成本。
  - **逐笔止损单扫描**（`process_crossing_stop_orders` + 止损连接）在**每一笔成交时对所有未成交订单执行一次 Seq Scan**（剖析显示 "Rows Removed by Filter: 2602"），即便没有任何止损单——呈 O(n) 增长。
  - Realtime 的 WAL 逻辑解码也作为后台负载出现（通过将行情数据移出 Postgres Changes 已将其最小化）。

### 优化：部分索引（`00040_ledger_perf_lockdown`）
`trade_order_stops_idx`——一个仅覆盖 STOPLOSS/STOPLIMIT 行的部分索引——将
逐笔止损探测从全表 Seq Scan 变为瞬时的 0 行索引扫描（计划已验证）。
体积极小（止损单罕见）；其收益随 `trade_order` 规模增长，防止随历史累积而使
每笔成交呈 O(n) 退化。

### 已测试的插件（78 个可用中的）
- **pg_stat_statements** —— 剖析撮合热路径（上文已用）。
- **pg_prewarm / pg_buffercache** —— 预热并检视热门订单簿/订单表的缓存。
- **hypopg** —— 在落地真实索引前做假设性索引的 what-if 分析。
- **pgstattuple** —— 对仅追加账本分区做膨胀检查。
- **pg_cron** —— 分区滚动 + 行情兜底推送器（已使用）。
- 还可备用：`plpgsql_check`、`pgmq`、`vector`、`pgaudit`、`pg_net`、`pg_partman`、`pg_repack`。

### 自定义 C 扩展 —— `oc_fastmath`（`ext/oc_fastmath/`）
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

#### oc_banker_round_numeric —— 引擎热门辅助函数的原生即插即用替代
`banker_round(numeric,int)`（四舍六入五成双）是结算路径上唯一真正受 CPU 限制的
辅助函数。通过服务器 numeric API 用 C 重新实现，与 PL/pgSQL 版本**逐位完全一致**
（在 20,012 个随机 + 边界用例上 0 处不符），且在**隔离场景下快约 2.8×**
（200 万次调用：C 1.46s vs PL/pgSQL 4.07s）。`build.sh` 默认将引擎的
`banker_round` 替换为 C 版本（以 supabase_admin 身份 DROP+CREATE；PL/pgSQL 函数体
按名称解析它）。已验证：在热路径采用 C 取整后，结算 + 全部 5 项对账不变量仍然通过。

#### 热点图谱与诚实的极限
剖析了每个热点并按性质分类（原生代码只对受 CPU 限制的工作有帮助；
PL/pgSQL 对受 SQL 限制的工作已做计划缓存）：

| 热点 | 性质 | 优化 |
|----------|--------|--------------|
| `create_trade` 结算（4× `process_transfer`，~2.4ms/笔） | **I/O**（堆插入 + WAL + 索引） | 结构性：UNLOGGED 订单簿、分区账本、降低 WAL |
| `banker_round`（numeric，五成双） | **CPU** | **原生 C，2.8×**（`oc_fastmath`） |
| 逐笔止损单扫描 | CPU+I/O（原为 O(n) 顺序扫描） | 部分索引 `00040_ledger_perf_lockdown` → O(log n) |
| `price_level` 更新 | I/O | UNLOGGED（`00040_ledger_perf_lockdown`） |
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

#### 批量账本写入（`9760`）
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

---

## 调优阶梯 —— 从基线到上限

吞吐量如何随着每一项优化的施加而攀升。在你自己的硬件上复现：
**[`scripts/bench-ladder.sh`](../scripts/bench-ladder.sh)** · [← BENCH.md](./PERFORMANCE.zh-CN.md) · [← README](../README.zh-CN.md)

</div>

> [BENCH.md](./PERFORMANCE.zh-CN.md) 报告的是**基线**（一个未经调优的单实例 PostgreSQL）—— 这是刻意设定的
> *下限*。本页讲的是*阶梯*：那些抬高上限的杠杆，按优先级排列，每一项都说明它做了什么、如何施加，
> 以及如何度量。用 `SERVICE=<key> ./scripts/bench-ladder.sh` 亲自跑一遍这套阶梯
> （先执行 `supabase db reset` 以获得干净的第 0 级）。

### 如何解读这些数字

这里每一笔“成交”都是一次**持久化、ACID、复式记账已结算**的撮合成交（约 8 次 insert + 4 次 update，
已提交到 WAL）—— 而不是一次内存中的订单簿操作。这一个事实就解释了整套阶梯：热路径
**受限于 WAL/fsync**，而不是 CPU 算术运算。所以最重要的杠杆，是那些改变*你向磁盘同步的频率与数据量*的
杠杆，以及那个增加*更多独立写入流*的杠杆（分片）。对算术做微优化几乎不会撼动端到端的数字。

> ⚠️ **请在一台空闲的机器上跑这套阶梯。** 持久化结算的吞吐量极度受 WAL/fsync 制约，以至于共享/开发
> 机器上的后台负载所产生的方差会淹没各项杠杆的效果（我们见过同一级在负载下读到 60/s、空闲时读到
> 230/s）。把任何单次嘈杂的运行都视为无意义；要比较的是在一台原本空闲的主机上背靠背测得的各级数据，
> 最好对若干次运行取平均。

### 阶梯

各级是**叠加的**（每一级都建立在前一级之上）。`agg` 列是 **N 个标的的聚合值** —— 即该配置下的
水平/分片上限（CEX 没有跨标的事务，因此各标的在每个合约的 advisory lock 之后完全并行运行）。

| rung | 改变了什么 | seq trades/s | p50 ms | 杠杆的方向 |
|---|---|---|---|---|
| **0** | 基线 —— `synchronous_commit=on`、`wal_compression=off`、PL/pgSQL `banker_round` | **~230** | **~4.5** | 参考下限 |
| **1** | `+ wal_compression=on` | ~顺序不变 | ~不变 | 减少 WAL **体积** → 对 IO 受限 / 复制有帮助，对单机 fsync 延迟无益 |
| **2** | `+ synchronous_commit=off` | **大幅跃升** | **大幅下降** | **最主导的杠杆** —— 停止提交时的 fsync（以崩溃时丢失最后几笔事务的持久性为代价） |
| **3** | `+ 原生 C 版 banker_round`（`ext/oc_fastmath`） | ~与第 2 级相同 | ~不变 | 把那个*微操作*加速约 2–3×，但算术并非瓶颈 → 端到端收益甚微 |
| **horizontal** | **按标的分片**（即 `agg` 列） | n/a | n/a | 在 WAL/IO 受限之前与标的数量近似线性 —— 这才是扩展 CEX 的真正途径 |

**实测的第 0 级基线**（16 vCPU · 27 GiB · PostgreSQL 17.6，空闲）：
**228 seq trades/s · p50 4.5 ms · p95 6.9 ms · p99 8.9 ms**，以及 **6 个标的并行聚合 1,066 trades/s**
（约为单标的速率的 4.7× —— 这就是分片杠杆，在基线配置下就已可见）。其余各级我们刻意留给你在自己的
硬件上用 `scripts/bench-ladder.sh` 填入，因为这些差值依赖于硬件与负载，发布捏造的、整齐划一的增量是不
诚实的。真正稳健的是其**形态**：`synchronous_commit=off` 是单机的最大胜负手；分片是水平方向的最大胜负
手；C 热路径和 `wal_compression` 对单机持久化吞吐量而言都属次要。

### 各项杠杆详解

#### 1. `synchronous_commit = off` —— 最主导的单机杠杆
默认情况下，每一次 COMMIT 都会等待 WAL 的一次 fsync。对于每个请求提交一笔已结算成交的负载来说，那次
fsync *就是*每笔成交的成本。把它关掉，让提交在 WAL 落盘之前就返回 —— 带来吞吐量的大幅提升和延迟的大幅
下降。
**权衡：** 崩溃时你可能会丢失最后几笔已提交的事务（不到一秒的成交）。对许多带有复制/PITR 的场所而言这是
可以接受的，对某些场所则不可接受 —— 由你定夺。
施加方式：`./scripts/perf-tune-local.sh RISKY=1`（或 `ALTER SYSTEM SET synchronous_commit=off`）。

#### 2. 按标的分片 —— 最主导的水平杠杆
撮合通过 `pg_advisory_xact_lock(instrument_id)` **按合约**串行化，因此不同标的永不相互阻塞，并能在单节点
上跨核扩展（即 `agg` 列）。由于 CEX **没有跨标的事务**，你还可以把各标的分片到*独立的*节点上，且**零 schema
变更** —— 每个分片都是同一套迁移、拥有互不相交的标的集合，置于一个无状态路由器之后，共享身份/钱包平面。
这是近似线性的，也是你越过单机上限的方式。参见 [PERFORMANCE.md](./PERFORMANCE.zh-CN.md) §1。

#### 3. UNLOGGED 内存订单簿 —— 已在迁移中
实时订单簿（`price_level` / `book_order`）是 **UNLOGGED** 的：订单簿变更不写 WAL，只有持久化账本才会被记
录。它默认开启（迁移 `00040_ledger_perf_lockdown`）；这在保持结算持久性的同时，消除了变动最频繁的表所带来的 WAL 压力。

#### 4. `wal_compression = on` —— IO 体积，而非 fsync 延迟
缩小 WAL 体积（对 IO 受限的机器、复制带宽以及 `max_wal_size` 余量有帮助）。它**不会**消除每次提交的
fsync，因此在单机上几乎不撼动顺序吞吐量 —— 它的价值在 IO 压力下、有副本时才会显现。由
`perf-tune-local.sh` 施加。

#### 5. 原生 C 版 `banker_round`（`ext/oc_fastmath`）—— 微操作，而非瓶颈
一个可直接替换的、舍入辅助函数的 C 实现，*就那一次调用而言*快约 2–3×。但银行家舍入在一笔由 WAL/锁/插入
主导的已结算成交事务中只占极小一片，所以替换它在持久化路径上端到端收益甚微。它出现在这里，是因为它是一个
干净的原生热路径扩展示例，并且对算术密集的批处理任务有帮助 —— 而不是因为它是结算的吞吐量杠杆。构建：
`./ext/oc_fastmath/build.sh`。

#### 6. 内存 / WAL 容量 —— 需要重启
`shared_buffers`、`work_mem`、`max_wal_size`、`effective_cache_size` 不可在运行时重新加载；在
`supabase/config.toml` 的 `[db]`（自托管）中设置并重启。更大的 `shared_buffers` 让热门订单簿和索引常驻
内存；更大的 `max_wal_size` 在写入突发时降低 checkpoint 频率。

### 批量下单（group commit）—— 调优批大小

> **首先，对齐这些数字 —— 两个不同的度量平面。** [BENCH.md](./PERFORMANCE.zh-CN.md) 中头条的
> **~200–270 trades/s/symbol** 是**引擎**速率，是在 **psql 循环中、无网络、服务端**测得的 —— 即
> 撮合+结算热路径的真实上限。下面的批处理表格是**客户端**速率，是**经 PostgREST/HTTP**测得的，其中每次
> 调用还要额外付出一次网络往返 + 鉴权。每次 HTTP 调用只下一个订单是*受往返制约*的，所以它远远**低于**引擎
> 上限 —— 那道差距是 HTTP 开销，而不是引擎本身慢。
>
> **批处理不会拖慢引擎。** 它在一次 HTTP 调用 / 一个事务中提交 N 个订单，因此把**客户端**速率*从每次调用
> 的往返下限抬升、趋向引擎上限*。它永远不可能超过引擎上限，也永远不会让单个订单的结算变慢。如果某张表里
> 批处理*低于*单笔，那是更长事务自身的成本（见拐点）或机器被争用所致 —— 而不是“调优让交易所变慢了”。
>
> **另外，不要把「单连接顺序 HTTP」当作吞吐能力。** 一次只发一个请求衡量的是*延迟*（每次约一个往返），不是吞吐。
> 真实吞吐来自**大量并发客户端**，其上限是引擎天花板（每个品种约 200–270 笔持久已结算成交/秒，6 个品种并行
> 约 560–730 笔/秒 —— 见 [BENCH.zh-CN.md](./PERFORMANCE.zh-CN.md)），并随品种数倍增。两位数的「订单/秒」只说明测量是
> 顺序的、或机器当时很忙 —— 不是系统的上限。

`submit_orders(account, instrument, jsonb[])`（迁移 `9765`）在**一个事务**中处理同一合约的 N 个订单：
一次 HTTP 往返、一次鉴权、一次 advisory-lock 获取、一次提交。持久化安全（`synchronous_commit` 保持为
on）—— 面向一次性下大量订单的做市商 / 流动性机器人。

**收益来自哪里（以及不来自哪里）：**
- **HTTP 往返摊销 —— 主要的、始终存在的收益。** 100 个订单装进 1 次调用而不是 100 次调用，省去了约 99
  次网络往返 + 鉴权。这就是为什么客户端速率随批大小攀升。
- **fsync 摊销 —— 仅在 fsync 慢的存储上。** 在 `synchronous_commit=on` 下，每批一次提交 = N 个订单一次
  fsync。在云端网络磁盘（fsync 昂贵）上这是一笔可观的额外收益；在本地 SSD/开发机（fsync 廉价）上则可忽略。
- **它不是引擎吞吐量的倍增器。** 在服务端（无 HTTP），对这种同一账户的负载做批处理大致是中性到略微负面的，
  因为那一个事务会在同一快照下把提交者自己的账户行重复更新 N 次。所以批处理关乎的是**客户端吞吐量 / 往返
  次数 / 原子的多订单提交**，*而非*让引擎本身比它约 270/s 的上限更快。

**存在一个拐点。** 客户端吞吐量随批大小上升（往返被摊销），随后趋于平台/回落（长事务持有每个合约的锁更久，
并不断翻动提交者的行），而每次调用的**延迟则近似线性增长**。所以要按*在你能接受的延迟下取得最大吞吐量*来
调优。用 **`SERVICE=<key> ./scripts/bench-batch.sh`** 度量。

⚠️ **下面的绝对数字是在一台被严重争用的开发机（负载 > 核心数）上测得的，因此被压低了数倍，绝不能拿来与
BENCH.md 的服务端数字相比。** 只有**相对形态**（×加速列以及拐点所在）才有意义；请用脚本在一台安静的机器上
复现真实数字。

| batch | 600 个订单所需的 HTTP 调用数 | orders/s（HTTP，被争用的机器） | 每次调用延迟 | 相对单笔 |
|---|---|---|---|---|
| 1（单笔） | 600 | 低（受往返制约） | ~30 ms | 1.0× |
| **10** | 60 | — | ~130–220 ms | ~1.2–2.4× |
| 25 | 24 | — | ~300–620 ms | ~1.1–2.5× |
| 50 | 12 | — | ~600–710 ms | ~1.9–2.7×（峰值） |
| 100 | 6 | — | ~1.2 s | 平台期 |
| 200 | 3 | — | ~3.5 s | 回落 |

**建议（客户端/HTTP 路径）：**
- **交互式 / 低延迟：** 批 **10–25** —— 在约 130–300 ms/调用下获得大部分往返收益。
- **吞吐优先（批量重新报价），延迟 ≲1 s 可接受：** 批 **~50** —— 接近拐点。
- **避免 ≥100**，除非延迟无关紧要 —— 吞吐进入平台期而延迟却升至数秒。
- 拐点会随网络 RTT、存储 fsync 成本和负载而移动 —— **在你自己的机器上跑 `bench-batch.sh`**，挑选其
  `orders/s` 接近最大值、且 `per-call ms` 可接受的最小批大小。

### 优先级顺序（先动哪个）

1. **`synchronous_commit=off`**（+ 复制/PITR 以保证持久性）—— 单机最大的胜负手。
2. **按标的分片** —— 越过单机的途径；近似线性、零 schema 变更。
3. **批量下单**（`submit_orders`，批 ~10–25）—— 对多订单提交者而言*客户端侧*最大的收益；摊销
   往返/鉴权/锁/提交。用 `bench-batch.sh` 调优。
4. 为你的工作集做**内存/WAL 容量**调整；UNLOGGED 订单簿已默认开启。
5. 若受 IO 或复制制约，则用 `wal_compression`。
6. 原生 C 热路径放到最后 —— 只有在你已证明瓶颈是 CPU 之后；而对于持久化结算来说，瓶颈通常并非 CPU。

> 底线：基线就已经每秒服务数百笔完全结算的成交；上限主要靠**放松每次提交的 fsync**与**增加并行写入流
> （标的）**来抬高 —— 用 `scripts/bench-ladder.sh` 为你的硬件复现完整的阶梯。

---

## 基准测试

可复现：**[`scripts/bench.sh`](../scripts/bench.sh)**（引擎）· **[`scripts/bench-batch.sh`](../scripts/bench-batch.sh)**（API）· [← README](../README.zh-CN.md)

</div>

### 两个维度 —— 引用任何数字前先把它们定义清楚

把这两者混为一谈，是发布「误导性基准」的头号原因。它们回答的是不同的问题：

| | **① 引擎吞吐** | **② API 吞吐** |
|---|---|---|
| 问题 | *撮合 + 结算引擎本身能跑多快？* | *客户端经由 API 端到端能拿到多少？* |
| 测量位置 | **服务端、库内**（psql 循环，无网络） | **经 PostgREST/HTTP**（每次调用含网络 + 鉴权） |
| 上限取决于 | PostgreSQL / WAL / CPU —— **这就是天花板** | 取决于维度 ①（可趋近，永不超过） |
| 旋钮 | `synchronous_commit`、分片、WAL、索引 | **并发** + **批处理** + 往返延迟 |
| 读者真正关心的数字 | **✅ 这个** | 集成层面的事，取决于你的客户端 |

> **「一笔成交」的含义。** 这里每一笔成交都是*完整、持久、双边记账已结算*的成交 —— 吃单被撮合**并且**
> 账本两边都已写入（约 8 次插入 + 4 次更新，落 WAL 提交）。这**不能**与内存 HFT 引擎报的「每秒百万次盘口
> 操作」相比 —— 那是非持久的盘口变更。pg-outcry 用原始速度换取**每一笔成交的 ACID 正确性**。

---

### ① 引擎吞吐（服务端）—— 撮合引擎的天花板

在 psql 循环里测、**不走网络**，从而隔离引擎本身。这是头条数字。

**环境：** 16 vCPU · 27 GiB · PostgreSQL 17.6，**未调优**（`shared_buffers=128MB`、
`synchronous_commit=on`、`wal_compression=off`），PL/pgSQL `banker_round`。这是**下限**，不是上限。

| 指标 | 结果 |
|---|---|
| **顺序吞吐**（单连接、单品种） | **每秒约 200–270 笔已结算成交** |
| 单笔已结算成交的引擎延迟 | **p50 ≈ 3.5 ms · p95 ≈ 6 ms · p99 ≈ 7–11 ms** |
| **并发扩展**（6 品种并行） | **每秒约 560–730 笔（合计）**（约 2.5–3.7×） |

- **按品种并发是真的。** 撮合按品种用 advisory lock 串行，不同品种完全并行 —— 合计吞吐随品种数上升。
  有几十个品种的交易所可继续扩展，直到 WAL/IO 成为瓶颈。
- **每笔成交都持久且为毫秒级。** 完全结算、ACID 提交的成交 p50 ≈ 3.5 ms。这就是维度 ② 所趋近的天花板。
- **余量：** `synchronous_commit=off`、原生 C `banker_round`、更大的 `shared_buffers`/`max_wal_size`，
  以及**跨节点按品种分片**可把它抬得更高 —— 逐级方法见 [TUNING.zh-CN.md](./PERFORMANCE.zh-CN.md)。

复现：`SERVICE=<key> ./scripts/bench.sh`。

---

### ② API 吞吐（客户端，经 PostgREST/HTTP）—— 受 ① 限制

它测的是*集成路径*，不是引擎。两个子要点，严格分开：

**延迟探针（不是吞吐）。** 单个订单、单连接、一次一个，衡量的是*延迟*：每次调用都付一个网络往返 + 鉴权。
开发机上端到端约为 **p50 ≈ 9 ms · p95 ≈ 22 ms**。**不要把「1000 / 9 ms ≈ 110 单/秒」当作系统能力** ——
那是*单个串行客户端*的延迟，不是吞吐。

**吞吐（真正的问题）= 并发 × 单请求，且以 ① 为上限。** 真实客户端使用大量并发连接；合计 API 吞吐随并发上升，
直到撞上引擎天花板（①）。**批处理**（`submit_orders`）是另一根杠杆：每次 HTTP 调用提交 N 笔，摊薄往返 +
鉴权 + 提交，于是*单个*客户端也能拿到其顺序速率的若干倍。批量大小（吞吐 vs 每次调用延迟）的调参见
[TUNING.zh-CN.md](./PERFORMANCE.zh-CN.md)。

复现：`SERVICE=<key> ./scripts/bench-batch.sh`（在 HTTP 上扫描批量大小与并发）。

> ⚠️ **请在空闲机器上测。** 两个维度都对其它负载敏感。在被占满的机器上（例如一台已被其它应用占满的 16 核笔记本），
> 绝对数字会下降数倍、并发也无法扩展（没有空闲核）—— 那反映的是机器状态，不是交易所。请在空闲主机上背靠背对比。

---

### 如何诚实地引用 pg-outcry

- **「单台未调优 Postgres 上，每个品种每秒约 200–270 笔持久、双边记账已结算的成交，6 个品种并行约 560–730 笔/秒；
  随品种与调优继续扩展。」** ← 引擎天花板（①）。这才是该下的结论。
- **不要**说「31 单/秒」—— 那是单个串行 HTTP 客户端的*延迟*，是维度 ② 的探针，且在繁忙机器上测得。它不是吞吐数字，
  也不是引擎。
- 它是**毫秒级持久**的，**不是**微秒级内存 HFT —— 何时*不该*用它见 [WHY.zh-CN.md](./WHY.zh-CN.md)。

> 结论：引擎在毫秒延迟下做到**每个品种每秒数百笔完全结算的成交**、并随品种扩展 —— 对其面向的中小交易所绰绰有余，
> 且有明确的继续提升路径（[TUNING.zh-CN.md](./PERFORMANCE.zh-CN.md)）。API 路径通过并发与批处理趋近该天花板；
> 单个串行连接只衡量延迟。

---

[← 返回文档](./README.md) · [← 项目 README](../README.zh-CN.md)
