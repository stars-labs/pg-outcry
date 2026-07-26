[English](./MIGRATIONS.md) · **中文**

# 迁移编号规范

所有迁移使用**5 位等宽、步长 10 的数字前缀**：`00010_`、`00020_` … `00910_`。

```
supabase/migrations/00010_engine_models_transfer_transfer_type.sql
supabase/migrations/00020_engine_models_trade_order_order_fill.sql
...
supabase/migrations/00930_admin_rbac_switch.sql
```

## 为什么要等宽

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

## 新增迁移

- **追加**：取当前最后一个文件之后的下一个 10 的倍数。
- **插入到两个迁移之间**：使用间隙中的空号（例如在 `00560_` 和 `00570_` 之间用
  `00565_`）。步长 10 的留白正是为此准备的。
- 不要复用编号；也不要修改**已经应用到线上数据库**的迁移的前缀（见下）。

## 给已部署的数据库重新编号

重命名迁移文件会改变它的 **version**，CLI 会把它当成新迁移并尝试重新应用。
而部分迁移在重放时是破坏性的（例如 `00580_cold_partitioning.sql` 里有
`drop table if exists trade cascade`），盲目重放会**丢数据**。

安全做法是改写已记录的 version，而不是重跑任何迁移：

```sql
-- 在事务中，把每个旧 version 字符串映射为新的
update supabase_migrations.schema_migrations set version = '00010' where version = '0001';
...
```

本地 / CI 数据库是一次性的 —— 直接 `supabase db reset` 即可。
