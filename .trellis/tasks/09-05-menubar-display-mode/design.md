# Design — Menu bar display mode

## 1. 数据源

共享 `UsageAggregator`（quota-alerts 已建）：`today` / `month` 的 `UsageBytes`（in+out 合并显示为单值，避免 60 pt 菜单栏过宽）。

## 2. 设置（SettingsStore 新增）

| 字段 | 默认 | 说明 |
|---|---|---|
| `showTodayInMenuBar` | false | 今日累计行 |
| `showMonthInMenuBar` | false | 本月累计行 |

与现有 showDownload/showUpload 并列；sink 写回。

## 3. StatusBarView

现有结构是两行（↗ 速率 / ↙ 速率）。追加：

- 今日行：`D 1.2G`（前缀 D + 合计，等宽 9 pt）
- 本月行：`M 8.3G`

行顺序：↑速率 / ↓速率 / 今日 / 本月。每行固定 height 10；菜单栏 length 已是 60（statusBarItem.length = 60，AppDelegate 里 sizeThatFits 由 hostingView 决定——验证多行时高度自适应：hostingView frame 高度设为菜单栏厚度，行多会溢出——**改法**：AppDelegate 的 `view.setFrameSize` 高度保持菜单栏厚度，内容 VStack 会压缩——需要把行高调小或让 hostingView fit。实现时验证：必要时 frame(height:) 用 NSStatusBar.thickness 并让 4 行以 9pt 挤入（4×10=40 > 24 厚度——**装不下**）。

**修正方案**：菜单栏厚度 ~24 pt 只容 2 行。多选时改为**单行横排**：`↑2K ↓800K · D1.2G · M8.3G`（一行 9 pt）。即显示模式=往现有单行追加紧凑段，而不是堆叠行。StatusBarView 重构为单 HStack。

## 4. 验证

- 开关即时反映；跨天 D 重置；与程序用量 Tab 今日总和同口径（±边界）。
- 三语设置文案。
