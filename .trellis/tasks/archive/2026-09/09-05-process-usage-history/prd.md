# Per-process usage history（所有程序的时间维度使用量）

## Goal

查看**所有程序**在不同时间维度（今天 / 最近 7 天 / 最近 30 天 / 自定义）的**上传/下载使用量与排名**——按程序累计用量 + Top 排名。

> 背景：`09-04-history-heatmap` 的 PRD 明确将"进程级历史归因"列为 out-of-scope；本任务把它补上，作为父任务 `09-04-history-window-and-usage` 的独立子任务。

## 核心设计约束（决定架构的关键事实）

1. **不能存原始帧**：进程级原始数据 ≈ 30 进程 × 43200 帧/天 = 130 万行/天，30 天即 4000 万行——必须**预聚合**。
2. **聚合键用显示名而非 pid**：进程会退出/重启，pid 不稳定；同名进程（Electron helpers）应合并统计——复用 m11 `mergeSameNameProcesses` 的语义（大小写不敏感、保留首拼写）。
3. **采样间隔可变（1/2/5 s）**：分钟桶的量 = `平均速率 × 60s`，与采样周期无关（同 heatmap 的 AVG 决策）。

## Scope

### In-scope
- **分钟级预聚合管道**：进程帧（已有，归一化后 bps）→ 内存累积当前分钟 → 分钟翻转时落盘。
- **`process_usage` 表**：`(minute_bucket, name, in_bytes, out_bytes)`，`name` 为合并后的显示名；索引 `(minute_bucket)`；retention 与总量历史一致。
- **查询**：任意时间范围内 `SUM(in_bytes), SUM(out_bytes) GROUP BY name` → 全列表 + 按列排序（名称/下载/上传/总量），与 popover 列表交互一致。
- **UI**：历史窗口加 **Tab 切换**：「热力图」（现有总量/接口视图）｜「程序用量」（进程表格：名称/↓/↑/合计 + 时间范围选择，复用 `HeatmapRange`）。范围与现有控件一致（今天/7/30 天/自定义）。
- 三语本地化（复用 `Loc.l`）。

### Out-of-scope
- 进程级**时间线热力图**（每程序一格一格的热力图）——先交付"累计用量 + 排名"（用户态信息价值最高、成本最低的形态）；时间线可作为后续增强。
- VPN/代理归因、按程序限速/断网——B 类（需 NetworkExtension），维持已定案边界。

## Requirements

- 聚合在后台队列完成，主线程只收结果；写库沿用 `HistoryPersistence` 的单一串行队列（同一 db 文件）。
- 速率→字节换算只发生在**分钟落盘**处一处（avg bps × 60）；下游查询只读字节列。
- 查询在 db 队列执行、结果回主队列；30 天范围查询 1 秒内完成。
- 零第三方依赖；部署目标 11.0；历史窗口新 Tab 文案三语。
- `process_usage` 的 `name` 口径与 popover 列表显示名一致（`getAppInfo` 的友好名？——**否**：落盘用 nettop 进程名（稳定），显示层再经 `getAppInfo` 映射友好名 + 图标）。

## Acceptance Criteria

- [ ] 运行 ≥2 分钟后，程序用量 Tab 能看到已产生流量的程序与字节数；数字随时间增长。
- [ ] 今天 / 7 天 / 30 天 / 自定义 四个维度查询结果一致（同一数据的不同聚合窗口）。
- [ ] 同名多进程（如 Electron helpers）的用量合并为一行。
- [ ] 进程退出后其历史用量仍保留、可查（按名聚合的效果）。
- [ ] 列排序（名称/下载/上传/总量）正确且即时。
- [ ] 30 天全量查询 < 1 s；主线程不触碰 sqlite。
- [ ] 纯逻辑（归一化→分钟桶→字节换算→聚合→过滤）通过 `verify_process_usage.swift` 15+ 用例。
- [ ] 三语文案完整；`xcodebuild build` 通过。

## Notes

- Complex task: `task.py start` 前需补 `design.md` + `implement.md` + jsonl（当前先落 PRD 定范围，待 heatmap 验证收尾后细化并启动）。
- 依赖关系：复用 heatmap 已落地的 `SharedStore.historyPersistence` 共享句柄与范围选择器模式。
