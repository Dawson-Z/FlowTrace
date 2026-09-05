# Data quota & threshold alerts（数据配额与阈值提醒）

## Goal

用户设定月/周/日周期的流量配额，用量达到 80% / 100% / 自定义阈值时发**本地通知**提醒——对应 Bytetally #6 的提醒侧（管控执行侧属 B 类，不在本任务）。

## Scope

- `SettingsStore` 新增配额配置：周期（月/周/日）、字节上限、阈值列表（默认 80/100，可加自定义 %）。
- 用量来源：`history` 表（总量速率）按周期起点 `SUM(avg×时长)` 累计——与 heatmap 聚合同口径；或直接对速率做时间加权积分（实现时定，design 细化）。
- 每帧（或每分钟）检查一次阈值跨越；跨越时经 `UNUserNotificationCenter` 发通知（每个周期+阈值只发一次，周期重置后恢复）。
- 可选：按接口类别独立预算（如"热点 Wi‑Fi 单独 10 GB"）——复用 `interface_history`。
- 设置面板新增 "Quota" 区（周期/上限/阈值编辑）。
- 三语。

## Out-of-scope

- 超额自动断网/限速（B 类，需 NE）。
- 按程序配额（依赖进程管控，B 类）。

## Acceptance Criteria

- [ ] 设小配额后快速触顶，收到一次 80% 与 100% 通知；周期内不重复。
- [ ] 周期翻转（如跨天）计数重置、可再次提醒。
- [ ] 菜单栏"本月用量"显示模式（menubar-display-mode 任务）可读到同一口径数值。
- [ ] 三语完整；主线程无 sqlite；`xcodebuild build` 通过。
