# Design — Full history heatmap（含接口历史）

## 1. 数据模型

在现有 `history(id, ts, in_bps, out_bps)`（总量历史，按帧）基础上，**同一数据库文件**新增接口历史表。

```sql
CREATE TABLE IF NOT EXISTS interface_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,        -- ms since epoch
    category TEXT NOT NULL,     -- InterfaceCategory.rawValue ("Wi-Fi"/"Wired"/"Local Direct"/"Other")
    in_bps INTEGER NOT NULL,
    out_bps INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_iface_ts_cat ON interface_history(ts, category);
```

复用 `HistoryPersistence` 的 db handle 与私有串行 queue（新增方法，不另起连接），这样 WAL、retention、单队列语义一致。`prune()` 同时清理 `interface_history` 超期行（同一 retentionSeconds）。

### 归一化（关键，单一归一点）
`InterfaceMonitor.onAggregate` 给出的 `bytesIn/Out` 是**采样窗口 delta**，非速率。写入前在 `Network.makeInterfaceMonitor` 回调里除以该机器的 `interval`（接口 monitor 当前的 `-s` 值）→ bytes/sec。**绝不在下游再除一次**，避免 m11 之前 issue #28 的重复归一化错误。

## 2. 接口历史写入管道

- 共享一个持久化实例：`Store.swift` 增加 `static let historyPersistence = HistoryPersistence(...)`（单例），供 `HistoryStore` 与 `Network` 复用同一 db/队列。
- `Network.makeInterfaceMonitor().onAggregate` 内：
  ```
  let in = snapshot.bytesIn[c] ?? 0; let out = snapshot.bytesOut[c] ?? 0
  → 除以 interval → 生成 [InterfaceHistoryRow] per category（ts=当前帧时间）
  → historyPersistence.appendInterface(rows)
  ```

## 3. 聚合查询

### 3.1 接口历史按范围聚合
`HistoryPersistence.interfaceHeatmap(from:to:categories:) -> [(day:Int, hour:Int, in:Int, out:Int)]`
- SQL：`SELECT CAST((ts + :tz)/3600000 AS INT) AS h, MAX(in_bps), MAX(out_bps) FROM interface_history WHERE ts>=? AND ts<? AND category IN (...) GROUP BY h ORDER BY h`。
- `:tz` = 本地时区相对 UTC 的毫秒偏移；SQLite 无时区概念，用偏移把 epoch-ms 归一到本地 hour bucket。
- day = h / 24，hour = h % 24。在 Swift 端二次累加成矩阵（SQL 只按本地小时粗分组，量小）。

### 3.2 总量历史（无类别）热力图
同 SQL，从 `history` 聚合，忽略 category 维度。

### 3.3 性能
30 天 × 2 s = ≤ ~1.3M 行；`ts` 已建索引，`WHERE ts BETWEEN` + `GROUP BY` 为索引扫描流式聚合，秒级内完成（验收 1s）。小时桶数 ≤ 720，Swift 矩阵很小。

## 4. 视图层（独立窗口）

- `HistoryWindowView`（SwiftUI，`NSHostingController` 承载）：
  - **顶部控制**：时间范围 `Picker`（segmented：today / 7d / 30d）+ 自定义起止 `DatePicker`（展示切换）；接口过滤 `Toggle` 组（4 类别，全选默认，**方式 B**：勾选组合累加，全选 = 总量）；**方向切换** `Picker` / `Toggle`（行=天/列=24h ↔ 列=天/行=24h）。
  - **主体**：`HistoryHeatmap` — 两种布局均由同一 `cells:[HeatmapCell]` 数据渲染：
    - **方向 1（行=天）**：每行一天，24 列小时（垂直堆叠天数）。
    - **方向 2（列=天）**：每列一天，24 行小时（GitHub 风格，横向滚动）。
    - 用 `ScrollView` + 手绘 `Rectangle` 单元格，颜色 = 强度梯度（`Color.primary.opacity(0.15…1)` 或按选中类别配色）。无数据 = 背景透明。
  - **悬停**：`onHover` 显示该时段 `↓/↑` 值。
- **数据源**：`HistoryHeatmapModel: ObservableObject`，持有当前范围 + 选中类别 + `cells`；参数切换即重新查询。

## 4.1 入口（popover 历史区）

- `HistoryView` 底部（sparkline + today peak / 24 h avg 之后）新增"完整历史"按钮，触发 `AppDelegate.showHistoryWindow()`。popover 其余内容不变。


## 5. 窗口管理

- `AppDelegate`：
  - `showHistoryWindow()` — 复用 `showSettingsWindow()` 的 lazy `NSWindow` 模式（`isReleasedWhenClosed=false`、`makeKeyAndOrderFront`）。标题 "History"。
  - 复用 `historyWindow` 缓存；不可见则重建 host。
- 入口见 **4.1**（popover 历史区按钮）。
- popover 主体内容**不变**：仍只显示 sparkline + today peak / 24 h avg + 接口总览当前活跃。

## 6. 线程与约束

- 所有 sqlite 写/读仍在 `HistoryPersistence` 的私有串行队列；结果经 `DispatchQueue.main.async` 回主线程。
- 不引入第三方库；部署目标 11.0；不用 macOS 13 Charts（手绘 `Path`/`Rectangle`）。
- `in_bps/out_bps` 保持 bytes/sec 语义；任何聚合不改变这一口径。

## 7. 验证策略

`xcodebuild test` 在该开发沙箱不可用 → 仿照 `verify_sort.swift` / `verify_merge.swift` 写 **`verify_history.swift`**：镜像"frame delta → 除以 interval 归一化 → 按 (day,hour) 桶聚合（含本地时区偏移）"的纯逻辑，跑 fixtures 断言，验证：
- 归一化只发生一次；
- 桶归类正确（跨日/跨小时边界）；
- 接口类别过滤正确；
- range 空窗口 / 无数据 → 全背景。

（单元测试文件 `HistoryHeatmapTests.swift` 同步放 `iTrafficPlusTests`，供 Xcode ⌘U 使用。）
