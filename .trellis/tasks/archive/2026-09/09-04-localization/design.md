# Design — Multi-language localization（中/英/繁，跟随系统 + 手动覆盖）

## 1. 机制

采用 Foundation 标准 `.lproj` + `NSLocalizedString` 家族，但通过一个**运行时语言管理器**支持"跟随系统 + 手动覆盖"，无需重启。

- **存储**：`SettingsStore` 新增 `languageOverride: String`（`nil` = 跟随系统；`"zh-Hans"` / `"en"` / `"zh-Hant"`）。写入 UserDefaults key `languageOverride`。
- **运行时选择 bundle**：`LocalizationManager`（单例）读取 override，用 `Bundle` 在 `Bundle.main` 所在的 app 内定位对应语言 `.lproj`，构造一个 `Bundle` 供取词：
  ```swift
  final class LocalizationManager: ObservableObject {
      @Published private(set) var locale: String  // 当前生效语言
      static let shared = LocalizationManager()
      func string(_ key: String, _ table: String = "Localizable") -> String {
          // null-resource 定位: 先试 override bundle, 再回退系统/Base
          bundle?.localizedString(forKey: key, value: nil, table: table) ?? key
      }
  }
  ```
- **视图取词**：所有用户可见文案改为 `Loc.l("key")`（`LocalizationManager.shared.string`），供 `Text(...)`、`TextField` placeholder、窗口标题等使用。`Text("key")` 的 SwiftUI 自动本地化不可用于自定义 bundle，故统一走 `Loc.l`。
- **重绘**：`languageOverride` 变更 → 更新 `LocalizationManager.locale` 并触发视图重读（通过 `@ObservedObject LocalizationManager.shared` 或环境值）。

## 2. 资源与 project.yml

- 目录：`ITrafficMonitorForMac/` 下建
  - `en.lproj/Localizable.strings`（Base 英文兜底同样提供）
  - `zh-Hans.lproj/Localizable.strings`
  - `zh-Hant.lproj/Localizable.strings`
- `project.yml`：
  - `FlowTrace` target `sources` 里把三个 `.lproj` 作为 resources 加入（`buildPhase: resources`），或依赖 XcodeGen 自动发现 `.lproj`。
  - 设置 `CFBundleLocalizations`（en / zh-Hans / zh-Hant）。
  - `developmentLanguage: en` 保留。

## 3. 文案抽取范围（实现时逐文件）

用户可见文案分布：
- `ContentView`：header（Upstream / Settings / Quit）、Sort 标签、（新增"完整历史"按钮文案）
- `HistoryView`：last 2 min / today peak / 24 h avg / ↓ / ↑
- `SettingsView`：General / Launch at login / Default sort / Case-insensitive search / Status bar / Show download / Show upload / History / Keep N days / Monitoring / Refresh interval / 1/2/5 seconds / Done /（新增 Language 下拉）
- `InterfaceSummaryView`：interface / 四类别名称展示 / top processes
- `StatusBarView`：下载/上传标签（如有）
- `ProcessSearchBar`：搜索占位符
- `AppDelegate`：窗口标题（Settings / History）

**语义 key 规则**：`InterfaceCategory.rawValue` 与持久化值**不翻译**（保持 "Wi-Fi"/"Wired"/"Local Direct"/"Other"），仅展示层经 `Loc.l(翻译映射)`。避免分类逻辑与 SQL 存储受语言影响。

## 4. 线程与约束

- 零第三方库；部署目标 11.0。
- 日志字符串不本地化。
- 语言覆盖是**运行时**偏好：改 `languageOverride` 立即重绘（不要求重启），与"跟随系统"一致时等价系统行为。

## 5. 验证

`xcodegen generate && xcodebuild build`（正常终端）通过；运行时分别设 override + 切系统语言观察文案；缺失 key 回退英文（Base）。因沙箱不能跑测试，关键点（bundle 定位/回退）用 `verify_loc.swift` 或仅构建+手动验证。
