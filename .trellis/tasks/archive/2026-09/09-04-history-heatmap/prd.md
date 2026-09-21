# Full history heatmap + arbitrary range（含接口历史）

## Goal

在现有 SQLite 历史基础上，提供一个**独立的历史窗口**：任意时间范围（预设+自定义）的**小时×天热力图**，且支持**按接口类别过滤**。popover 保持当前活跃状态（sparkline + today peak / 24 h avg）不动，历史窗口单独打开。

> 范围来自用户决策（2026-09-04）：本次**含接口历史持久化**；历史不放进 popover，单开一个窗口；时间范围做"预设 + 自定义"。

## Scope

### In-scope
- **接口历史持久化**：新增接口历史表，把 `InterfaceMonitor` 每帧按 `InterfaceCategory` 的 in/out 字节写入库（含归一化到 bytes/sec），支持按接口类别查询历史。
- **独立历史窗口**：popover 底部历史区新增入口（"完整历史"按钮），打开一个独立 `NSWindow`（复用 `showSettingsWindow` 的 lazy-window 模式），承载历史视图。
- **时间范围选择器**：今天 / 最近 7 天 / 最近 30 天 预设 + 自定义起止日期。
- **小时×天热力图**：每格 = 该（小时，天）桶的流量强度；悬停显示实际值。支持**两种方向切换**（行=天/列=24h 与 列=天/行=24h）。
- **接口类别过滤（方式 B）**：一张热力图 + 顶部 4 类别复选框（toggle），勾选组合累加，全选 = 总量。

### Out-of-scope（明确排除）
- 配额 / 限速 / 断网 / 导出 / 菜单栏切换：见父任务 `09-04-history-window-and-usage` 其它子任务。
- 每接口 Top 进程历史、进程级历史归因——本次只做"总量 + 接口类别"两个维度。

## Requirements

- **接口持久化表**：`interface_history(ts, category, in_bps, out_bps)`，`ts` 为 ms-since-epoch，`category` 存 `InterfaceCategory` 的原始值。索引 `(ts, category)`。
- **归一化**：`InterfaceMonitor` 的 `bytesIn/Out` 是采样窗口内的 delta，写入前除以其 `interval` 归一化为 bytes/sec（单一归一点：接口数据进入 app 的入口）。
- **聚合查询**：按时间范围从 `history`（总量 in/out）与 `interface_history`（按类别）取数，聚合成"小时×天"矩阵；范围上限 30 天。
- **热力图**：颜色梯度表达强度（最强为满色，无数据为背景色），悬停显示该时段 in/out 值。不用 macOS 13 Charts，用 `Path`/`Shape` 手绘（部署目标 11.0）。
- **线程**：新增查询全部在 db 私有串行队列执行，主线程从不接触 `sqlite3_*`；结果回主队列。
- **零第三方依赖**；速率字段语义不变（bytes/sec）。

## Acceptance Criteria

- [ ] 运行一段时间后，`interface_history` 表按帧累积类别数据；重启不丢。
- [ ] 历史窗口可从 popover 头部打开、可关闭，窗口复用（不重复创建）。
- [ ] 选时间段（今天/7/30 天/自定义）后，热力图显示对应行（天）×列（小时）网格，着色正确。
- [ ] 接口类别过滤生效：只选"有线"时，热力图只反映 wired 类别；全选 = 全部。
- [ ] 无数据时段为背景色，不会误显为有流量。
- [ ] 悬停单元格显示该时段 in/out 值；布局自适应窗口宽度。
- [ ] 30 天范围一次聚合在 1 秒内完成（索引扫描 ≤ 约 302 400 行数量级）。
- [ ] popover 现有 sparkline / today peak / 24 h avg 不受影响。
- [ ] 聚合逻辑通过 `verify_history.swift`（或等效 standalone 脚本）验证；该开发沙箱不能跑 `xcodebuild test`。
- [ ] 主线程从不直接调用 `sqlite3_*`。

## Notes

- Complex task: 需 `design.md`、`implement.md`，并在 `task.py start` 前配置 `implement.jsonl` / `check.jsonl`。
