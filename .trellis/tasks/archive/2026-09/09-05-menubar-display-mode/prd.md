# Menu bar display mode（菜单栏显示模式切换）

## Goal

菜单栏除现有"实时上下行速率"外，支持切换/追加显示**今日累计**与**本月累计**。让"今天用了多少/这个月用了多少"不必开窗可见。

## Scope

- 设置面板 "Status bar" 区新增显示内容选择（多选）：实时速率（默认）/ 今日累计 / 本月累计。
- 累计口径与 quota-alerts 的用量积分**同一实现**（共享一个 UsageAggregator，避免两处口径漂移）。
- 布局：菜单栏宽度有限——累计行用紧凑格式（如 `1.2 GB` 单值，或 `↓980M ↑120M`，design 定）；多选时纵向堆叠（现有 ↗↙ 结构扩展）。
- `StatusBarView` 读取 aggregator 的 `@Published` 值；更新频率与 nettop 帧一致。
- 今日/本月起点用本地日历（`Calendar.startOfDay` / 月首），跨天/跨月自动重置。
- 三语（设置项文案；菜单栏数字本身无文案）。

## Dependencies

- 用量积分逻辑建议与 `09-05-quota-alerts` 一起落地（同一个 `UsageAggregator`），若先做本任务则先实现积分器最小版。

## Out-of-scope

- 额度百分比显示（依赖 quota-alerts 落地后追加一行）。

## Acceptance Criteria

- [ ] 三种内容可独立开关，菜单栏即时反映。
- [ ] 今日累计与程序用量 Tab 的"今天"总和同口径（±采样边界差）。
- [ ] 跨天瞬间累计清零、无崩溃。
- [ ] 菜单栏宽度自适应不换行错位。
- [ ] 三语；`xcodebuild build` 通过。
