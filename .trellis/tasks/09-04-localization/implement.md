# Implement — Multi-language localization（中/英/繁）

> 先本地化（基础设施先行），history 新文案随后直接走本地化。

## Ordered Checklist

### 1. 语言管理器 + 基础设施
- [ ] 新建 `iTrafficPlus/Feature/Localization/LocalizationManager.swift`：`ObservableObject` 单例，定位 `.lproj` bundle，`Loc.l(_:)` 取词，`locale` 随 `languageOverride` 重载（缺失回退 Base/系统）。
- [ ] 新建 `iTrafficPlus/Feature/Localization/LocalizableKey.swift`（可选）：集中 key 常量，避免魔法字符串。

### 2. SettingsStore 增加语言覆盖
- [ ] `SettingsStore` 新增 `@Published var languageOverride: String?`（key `languageOverride`，init 读 defaults，sink 写回）。
- [ ] `LocalizationManager` 订阅 `SettingsStore.shared.$languageOverride` 更新 `locale`。

### 3. 资源 + project.yml
- [ ] `ITrafficMonitorForMac/` 下新建 `en.lproj/` `zh-Hans.lproj/` `zh-Hant.lproj/` 各一个 `Localizable.strings`（英文兜底放 en.lproj）。
- [ ] `project.yml`：把三个 `.lproj` 加进 `iTrafficPlus` target resources；设 `CFBundleLocalizations`（en/zh-Hans/zh-Hant）。

### 4. 抽取文案
- [ ] `ContentView`、`HistoryView`、`SettingsView`、`InterfaceSummaryView`、`StatusBarView`、`ProcessSearchBar`、`AppDelegate`（窗口标题）——所有用户可见字符串改为 `Loc.l("key")`。
- [ ] 四类别展示经 `Loc.l` 翻译；`InterfaceCategory.rawValue` 与持久化/分类逻辑**不变**。

### 5. 设置面板语言下拉
- [ ] `SettingsView` 新增 "Language" 行：`Picker`（跟随系统 / 简体中文 / 英文 / 繁体中文）绑定 `languageOverride`。

### 6. 验证
- [ ] 生成三语文案并填入 `.strings`（zh-Hant 用繁体字形，勿漏）。
- [ ] `xcodegen generate && xcodebuild build`（正常终端）通过。
- [ ] 运行：切换系统语言 / 设置里切 override，界面即时变化；缺失 key 回退英文。
- [ ] history/interface/settings 均不回归。

## Validation Commands

```bash
xcodegen generate
xcodebuild build -project iTrafficPlus.xcodeproj -scheme iTrafficPlus -configuration Debug
```

## Review Gates
- 日志字符串保持英文。
- 分类存储 key 不随语言变。
- 缺失翻译回退 Base 英文，不显示 key。
- 语言覆盖运行时可切换（不要求重启）。

## Rollback Points
- 若 bundle 定位异常：回退到纯"跟随系统"（去掉 override + `Loc.l` 直接走 main bundle）。
- 若某文件抽取破坏 UI：`git checkout -- <file>` 还原该文件。
