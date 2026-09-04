# Multi-language localization（中/英/繁）

## Goal

为 iTrafficPlus 提供**简体中文 / 英文 / 繁体中文**（zh-Hans / en / zh-Hant）界面，当前界面文案**全部硬编码英文**，需抽取为可本地化资源。

## Background

- 现状：无 `Localizable.strings`；除 `Base.lproj/Main.storyboard` 外无任何语言 `.lproj`；`project.yml` `developmentLanguage: en`。用户可见文案硬编码在 `ContentView`、`HistoryView`、`SettingsView`、`InterfaceSummaryView`、`StatusBarView`、`ProcessSearchBar`、`AppDelegate`（窗口标题）等文件。
- 语言范围（用户已定）：en（英文）、zh-Hans（简体）、zh-Hant（繁体）。

## Scope

### In-scope
- 抽取所有**用户可见**字符串到 `Localizable.strings`（按语言 `.lproj`）。
- `project.yml` 增加 `CFBundleLocalizations`（en / zh-Hans / zh-Hant）与对应资源；`Base.lproj` 提供英文兜底。
- 界面文案替换为 `LocalizedString` 依赖/`NSLocalizedString`/`Text("key")`；动态文案自行使用 `String(format:)` 化的本地化 key。
- 窗口标题、菜单/按钮文案、搜索占位符、日期/时间显示格式（如适用）一并本地化。

### Out-of-scope
- 日志字符串（`Log.*`）——开发者可见，保持英文，不做本地化。
- 图标、SF Symbols、颜色——无本地化。
- 接口类别名称（Wi-Fi / Wired / Local Direct / Other）等**数据语义**值：改为本地化后显示，但存储/匹配仍用稳定英文 key（如 `InterfaceCategory.rawValue` 不改，仅展示层翻译）。

## Requirements

- 采用 Foundation 标准本地化机制（`.lproj` + `NSLocalizedString` / SwiftUI `Text("key")`），部署目标 11.0 可用。
- 语言切换机制（待确认）：默认**跟随系统**语言；如用户要求，可再提供**应用内手动覆盖**（Setting 加"语言"选项）。
- 缺失翻译回退英文（Base 兜底），不得显示 key 本身。
- 不引入第三方本地化库。

## Acceptance Criteria

- [ ] 系统语言分别设为 简体中文 / 英文 / 繁体中文 时，界面各主要文案对应显示。
- [ ] 无用户可见的硬编码英文字符串残留（除日志/开发者面）。
- [ ] 缺失翻译时回退英文，不显示 key。
- [ ] 接口类别在界面按语言翻译展示，但底层分类逻辑与持久化 key 不变。
- [ ] `xcodegen generate && xcodebuild build` 通过（正常终端）。
- [ ] 零第三方依赖；部署 11.0；不影响既有功能（history/interface/settings 均不回归）。

## Notes

- Complex task: 需 `design.md`、`implement.md`，并在 `task.py start` 前配置 `implement.jsonl` / `check.jsonl`（如采用 sub-agent dispatch；本环境退化为 inline 实现）。
