# Implement — Full history heatmap（含接口历史）

> 执行顺序遵循：数据层 → 写入管道 → 聚合 → 视图 → 窗口/入口 → 验证 → 收尾。

## Ordered Checklist

### 1. 数据层（`iTrafficPlus/Feature/History/HistoryPersistence.swift`）
- [ ] 新增 `interface_history` 表 + `idx_iface_ts_cat`（`createSchemaIfNeeded` 内）。
- [ ] `prune()` 同时清理 `interface_history` 超期行。
- [ ] 新增 `struct InterfaceHistoryRow { ts, category, inBps, outBps }`。
- [ ] 新增 `appendInterface(_ rows:)`（异步，走同一 queue）。
- [ ] 新增 `interfaceHeatmap(from:to:categories:)` 聚合查询（返回 `[HeatmapCell]`，含本地时区偏移）。
- [ ] 新增 `historyHeatmap(from:to:)` 总量聚合查询（复用同一桶逻辑）。

### 2. 共享持久化单例（`ITrafficMonitorForMac/Store.swift`）
- [ ] 增加 `static let historyPersistence = HistoryPersistence(...)`（供 `HistoryStore` 与 `Network` 共享 db/queue）。
- [ ] `HistoryStore` 改为注入此单例（保持现有 `bootstrap`/`append`/`summary` 不变）。

### 3. 接口写入管道（`ITrafficMonitorForMac/Network.swift`）
- [ ] `makeInterfaceMonitor().onAggregate` 内：按 `interval` 归一化 `bytesIn/Out` → 组装 `InterfaceHistoryRow` → `historyPersistence.appendInterface(rows)`。
- [ ] 确认**不**在下游重复除以 interval。

### 4. 热力图模型（`iTrafficPlus/Feature/History/HistoryHeatmapModel.swift` 新建）
- [ ] `ObservableObject`：`@Published range`、`@Published selectedCategories`、`@Published cells`。
- [ ] `reload()`：调 `historyPersistence` 聚合，主队列回填 `cells`。
- [ ] 参数切换触发 `reload()`。

### 5. 热力图视图（`iTrafficPlus/Feature/History/HistoryHeatmapView.swift` 新建）
- [ ] `HistoryHeatmap`：`ScrollView` + 手绘 `Rectangle` 网格，支持**两种方向**（行=天/列=24h；列=天/行=24h），由同一个 `cells` 渲染，方向可切换。
- [ ] `onHover` 显示该时段 `↓/↑` 值。
- [ ] 无数据单元格 = 背景色。

### 6. 历史窗口（`iTrafficPlus/Feature/History/HistoryWindowView.swift` 新建）
- [ ] 顶部时间范围 `Picker`（today/7d/30d）+ 自定义 `DatePicker`（展示切换）。
- [ ] 接口类别 `Toggle` 组（方式 B：4 类复选框，勾选组合累加，全选默认，全选 = 总量）。
- [ ] 方向切换 `Picker`（行=天/列=24h ↔ 列=天/行=24h）。
- [ ] 主体嵌入 `HistoryHeatmap`。

### 7. 窗口管理与入口
- [ ] `AppDelegate.showHistoryWindow()`（lazy `NSWindow`，标题 "History"，复用缓存）。
- [ ] `HistoryView` 底部（sparkline + today peak / 24 h avg 之后）新增"完整历史"按钮，触发 `showHistoryWindow`。

### 8. 验证
- [ ] 新建 `verify_history.swift`（standalone，镜像归一化+桶聚合+接口过滤），运行全 PASS。
- [ ] 新建 `iTrafficPlusTests/HistoryHeatmapTests.swift`（供 Xcode ⌘U）。
- [ ] `xcodegen generate && xcodebuild build` 编译通过（在正常终端）。
- [ ] 运行 app：观察 `interface_history` 累积、历史窗口打开、热力图着色、接口过滤、范围切换。

## Validation Commands

```bash
swift verify_history.swift          # 归一化/桶聚合/过滤 全部 PASS
xcodegen generate                   # 正常终端执行
xcodebuild build -project iTrafficPlus.xcodeproj -scheme iTrafficPlus -configuration Debug
```

## Review Gates
- 归一化只在写入点发生一次（对照 issue #28）。
- `in_bps/out_bps` 语义不变。
- 主线程无 sqlite 调用；查询回主队列。
- popover 现有内容不回归。

## Rollback Points
- 若接口历史写入导致 `HistoryPersistence` 出错：回退第 1–3 步（保留只读聚合，去掉写库）。
- 若历史窗口 UI 有回归：回退第 4–7 步（下掉入口，popover 回到 m8 状态）。
- 任何一步无法 `xcodebuild build`：定位到最近一次编辑，`git checkout -- <file>` 还原该文件后重来。
