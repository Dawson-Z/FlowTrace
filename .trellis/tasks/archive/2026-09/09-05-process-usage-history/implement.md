# Implement — Per-process usage history

> 数据层 → 聚合器 → 接入 → UI → 验证，与 heatmap 相同节奏。

## Ordered Checklist

### 1. 数据层（`HistoryPersistence.swift`）
- [ ] `process_usage` 表 + `idx_pu_minute`（`createSchemaIfNeeded`）。
- [ ] `prune()` 加入第三张表。
- [ ] `struct ProcessUsageSummary { name, inBytes, outBytes }`。
- [ ] `appendProcessUsage(rows: [(minuteBucket, name, nameKey, inBytes, outBytes)])`（异步事务批量）。
- [ ] `processUsage(fromBucket:toBucket:completion:)` 聚合查询（GROUP BY name_key，主队列回调）。

### 2. 聚合器（`FlowTrace/Feature/History/ProcessUsageAggregator.swift` 新建）
- [ ] 私有串行队列；`feed(entities:interval:now:)` 累积 sumBps。
- [ ] 分钟翻转 flush：`bytes = sumBps × interval`，组 rows 回调落盘。
- [ ] `flush(using:interval:)` 供 interval 变更前强制结算。

### 3. 接入（`Network.swift`）
- [ ] `handleFrame` 尾部 `aggregator.feed(...)`。
- [ ] `applyRefreshInterval` 更新 interval 前先 `flush(using: interval)`。

### 4. 模型与视图
- [ ] `ProcessUsageModel.swift`：range/sortMode/rows + reload（minute bucket 换算）。
- [ ] `AppUsageView.swift`：范围/排序控件 + 表格（图标/名称/↓/↑/合计）+ 总计行 + 空态。
- [ ] `HistoryWindowView`：顶部 Tab（Heatmap | App usage），切 Tab 保各自状态。

### 5. 本地化
- [ ] 三语 strings：`Heatmap` / `App usage` / `no usage recorded`（及表头复用）。

### 6. 验证与收尾
- [ ] `verify_process_usage.swift` 15+ 用例全 PASS。
- [ ] `xcodegen generate && xcodebuild build`（正常终端）通过。
- [ ] 用户 GUI 验证：运行数分钟后 Apps 标签出现数据、四维度一致、同名合并、退出进程用量保留。
- [ ] changelog m14 + commit + journal + archive。

## Validation Commands

```bash
swift verify_process_usage.swift
xcodegen generate && xcodebuild build -project FlowTrace.xcodeproj -scheme FlowTrace -configuration Debug
```

## Review Gates
- 速率→字节换算只在 flush 一处（sumBps × interval）。
- 主线程无 sqlite；聚合器线程安全。
- interval 变更前必须 flush 旧窗口。
- 查询 GROUP BY name_key（不分裂大小写变体）。

## Rollback Points
- 聚合器异常：移除 feed 接入（表保留，无 UI 依赖即无回归）。
- UI 回归：Tab 回退到 Heatmap 单页。
