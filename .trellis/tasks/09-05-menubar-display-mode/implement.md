# Implement — Menu bar display mode

1. [ ] SettingsStore：showTodayInMenuBar / showMonthInMenuBar + sink。
2. [ ] StatusBarView 重构为单行横排：`↗rate ↙rate · D1.2G · M8.3G`（仅显示开启项）；读 `SharedStore.usageAggregator`。
3. [ ] AppDelegate：hostingView 宽度按内容估算（60 → 动态，或固定 110 当开启累计时）。
4. [ ] 三语设置文案（Show today total / Show month total）。
5. [ ] 编译 + GUI 验证（开关即时、跨天重置、口径与 App usage 一致）→ changelog + commit + archive。
