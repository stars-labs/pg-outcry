[English](./DEPLOY.md) · **中文**

# 部署

同一套迁移脚本对应两种部署方案：

| | **演示 — 托管 Supabase**（supabase.com） | **本地高性能**（自建） |
|---|---|---|
| 部署位置 | 托管的 Supabase 项目 | 在你的机器上 `supabase start` / 你自己的 Postgres |
| 迁移脚本 | ✅ 全部（特权操作自动跳过） | ✅ 全部 |
| 撮合 / 结算 / 钱包 / 鉴权 / RLS / 风控 / 后台 | ✅ | ✅ |
| 实时（私有推送 + 广播行情数据） | ✅ | ✅ |
| 分区 + `pg_cron` 滚动 | ✅（在控制台中启用 `pg_cron`） | ✅ |
| UNLOGGED 热点订单簿 | ✅（单一主库；故障切换后需重建） | ✅ |
| **自定义 C 扩展**（`oc_fastmath`，原生 `banker_round`） | ❌ 托管环境不允许 → 改用 PL/pgSQL | ✅ `ext/oc_fastmath/build.sh` |
| 按角色设置 `statement_timeout`、`wal_compression` 等 | 在控制台中设置 | ✅ `scripts/perf-tune-local.sh` |

迁移脚本被设计为**优雅降级**：那些需要发布（publication）/角色所有权或超级用户权限的操作
（例如 `ALTER PUBLICATION … SET publish_via_partition_root`、`ALTER ROLE … SET statement_timeout`、
`CREATE EXTENSION pg_cron`、`cron.schedule`）都被包裹在尽力而为（best-effort）的代码块中，因此即便
这些操作在托管项目中受限，`supabase db push` 仍能成功执行。

---

## 演示：部署到托管 Supabase

```bash
supabase login
supabase link --project-ref <your-project-ref>
supabase db push                 # applies every migration; privileged ops self-skip
```

如果浏览器登录或 `supabase login --token ...` 流程卡住，可以绕过交互式登录，
直接通过环境变量传入 Supabase Dashboard access token：

```bash
read -rs SUPABASE_ACCESS_TOKEN   # 粘贴 Supabase Dashboard access token
export SUPABASE_ACCESS_TOKEN

supabase link --project-ref <your-project-ref>
supabase db push --yes
```

不要提交、粘贴或把 access token 留在 shell history 中。如果 token 在部署过程中暴露过，
请立即 revoke 并重新生成。

当前公开演示项目为：

```bash
PROJECT_REF=axtziasfallmdgssbgsl
API=https://axtziasfallmdgssbgsl.supabase.co
```

托管演示已经应用到 `99999_admin_rbac.sql`。管理后台当前故意采用**测试开放模式**：
每个已登录的 Supabase Auth 用户都会获得完整管理员权限，方便评审人员试用后台。
上线生产前，应将 `admin_has_permission()` / `current_admin_permissions()` 收紧回
基于 `admin_operator_role` 的 RBAC，并在需要预审批运营账号时关闭开放注册。

然后在 Supabase 控制台中：
1. **Database → Extensions**：启用 `pg_cron`（用于分区滚动 + 可选的 1 秒
   行情数据兜底）。可选启用 `pg_stat_statements`、`hypopg` 以便性能分析。
2. **Database → Roles**（可选）：为 `authenticated`（15s）/ `service_role`（30s）
   设置 `statement_timeout` —— 在缺少所有权时迁移会跳过这些设置。
3. **行情数据**：将合并后的 L2 行情推送器作为外部客户端，针对你的
   项目运行（它只需要 service key）：
   ```bash
   API=https://<ref>.supabase.co SERVICE=<service_role key> node examples/md-ticker.mjs
   ```
   （或注册纯 PG 的 1 秒兜底方案：`select cron.schedule('md','1 seconds','select broadcast_md()')`）。

托管环境下你能获得：完整的纯 PG CEX —— PostgREST API、Auth+RLS、私有
实时推送、广播行情数据、钱包、风控、后台。`banker_round`
以 PL/pgSQL 运行（与 C 版本逐位一致，只是每次调用更慢）。

> 托管环境注意事项：UNLOGGED 的 `book_order`/`price_level` 不纳入 PITR/副本；故障切换后
> 运行 `select rebuild_book();` 以从未成交订单重建实时订单簿。

---

## 本地高性能：自建

```bash
supabase start
supabase db reset                # apply all migrations

export ANON="$(supabase status -o json | jq -r .ANON_KEY)"
export SERVICE="$(supabase status -o json | jq -r .SERVICE_ROLE_KEY)"

# native C banker_round (drop-in, ~2.8x) + DB tunables
./scripts/perf-tune-local.sh

# market-data ticker (100ms coalesced L2 broadcasts)
SERVICE="$SERVICE" node examples/md-ticker.mjs &
```

`scripts/perf-tune-local.sh`：
- 构建并加载 `oc_fastmath`，将 `banker_round` 替换为原生 C（`ext/oc_fastmath/build.sh`）；
- 以 `supabase_admin` 身份通过 `ALTER SYSTEM` 应用写入吞吐调优参数
  （`wal_compression=on`；可选的 `synchronous_commit=off` 以换取最大吞吐量，代价是
  崩溃时会丢失最近几笔已提交的事务 —— 通过 `RISKY=1` 显式启用）。

在每次 `supabase db reset` 之后都要重新运行 `./scripts/perf-tune-local.sh`（reset 会删除
C 版 `banker_round` 并回退到 PL/pgSQL；`.so` 文件仍保留在 PGDATA 中）。

## 两种方案的共同之处
相同的 schema、相同的引擎、相同的 API 接口、相同的测试（`scripts/smoke-*`）。唯一的
运行时差异在于原生 `banker_round`（本地）以及数据库层面的调优参数（本地 /
控制台）。从功能上看，托管演示版和本地构建版是同一个纯 PG 交易所。
