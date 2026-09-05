# Design — Per-process usage history

## 1. 数据模型

同一 db 文件新增：

```sql
CREATE TABLE IF NOT EXISTS process_usage (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    minute_bucket INTEGER NOT NULL,  -- local minute: (tsMs + tzMs) / 60000
    name TEXT NOT NULL,              -- first-seen spelling (display)
    name_key TEXT NOT NULL,          -- lowercased (grouping key, pid-stable across restarts)
    in_bytes INTEGER NOT NULL,
    out_bytes INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pu_minute ON process_usage(minute_bucket);
```

`name_key` 分离的原因：SQLite `GROUP BY name` 是 BINARY 比较会分裂 "node"/"Node"；按 `name_key` 分组、`MAX(name)` 取显示拼写。retention/prune 与其它表一致。

## 2. 聚合管道 `ProcessUsageAggregator`

- `feed(entities:interval:)`：由 `Network.handleFrame`（nettop 队列）调用。内部私有串行队列保护状态。
- 累积：`key = name.lowercased()` → `(sumInBps, sumOutBps, firstName)`。同名多 pid 天然合并（等价 m11 语义）。
- 分钟翻转（新帧的 minute ≠ 累积 minute）→ **flush**：每 key 一行
  `in_bytes = sumInBps × interval`（每帧 bps 代表 interval 秒的字节量，SUM 即窗口真实字节——比 avg×60 更准，且天然覆盖不足整分钟的窗口）。
- flush 后开新桶。`applyRefreshInterval` 在更新 interval **前**调用 `flush(using: oldInterval)`，避免跨间隔窗口算错。
- 写库走 `HistoryPersistence.appendProcessUsage(rows)`（同一串行 db 队列，主线程零 sqlite）。

## 3. 查询

`processUsage(fromMs, toMs, completion:)` → `[ProcessUsageSummary]`：

```sql
SELECT MAX(name), SUM(in_bytes), SUM(out_bytes)
FROM process_usage
WHERE minute_bucket >= :fromBucket AND minute_bucket < :toBucket
GROUP BY name_key
ORDER BY SUM(in_bytes)+SUM(out_bytes) DESC;
```

`minute_bucket` 边界由 Model 用与 heatmap 相同的本地时区换算得出。30 天 ≈ 4.3 万行 × 进程数÷合并，索引扫描秒级内。

## 4. UI

- `HistoryWindowView` 顶部加 **Tab Picker**：`Heatmap`（现有）｜ `App usage`。
- `AppUsageView`（新）：
  - 范围选择复用 `HeatmapRange`（今天/7d/30d/自定义 + DatePicker），换算成 minute_bucket。
  - 排序 `Picker` 复用 `ListSortMode`（Name/Down/Up/Total），与 popover 一致。
  - 表格：图标（`getAppInfo(pid:0, name:)` 尽力解析）+ 名称 + ↓ + ↑ + 合计；底部总计行。
  - 空数据显示"no usage recorded"提示。
- `ProcessUsageModel: ObservableObject`：range/sortMode/rows，didSet → reload（模型层 didSet 在写入后触发，无 willSet 竞态；视图绑定点若出现延迟一拍，按 spec 的 @State 镜像模式处理）。

## 5. 本地化

新增 keys：`Heatmap` / `App usage` / `App usage tab` 提示语 / `no usage recorded`（三语）。其余复用。

## 6. 验证

`verify_process_usage.swift`：累加归一化（sumBps×interval）、分钟翻转 flush、同名合并（大小写）、interval 变更前 flush、查询范围换算、空范围、排序正确性——15+ 用例。
