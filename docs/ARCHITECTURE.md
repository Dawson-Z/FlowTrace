# FlowTrace 技术架构与目录说明

> 本文档基于当前工作区源码（`0.3.0` / research milestone 22）逐文件梳理而成。
> 文中所有类型名、方法名、key 字符串、SQL 表名均取自真实代码；引用注释处标注了原文。
> 最后一节记录了若干「注释/README 与实际实现不一致」的地方，便于后续维护。

---

## 1. 项目定位与硬约束

FlowTrace 是 [foamzou/ITraffic-monitor-for-mac](https://github.com/foamzou/ITraffic-monitor-for-mac)（iTraffic）的**私有、本地、不发布**研究分支。它在保留上游「驱动 `/usr/bin/nettop` 的菜单栏按进程流量监控」这一核心思路的基础上，叠加了一批纯用户态的实验特性。

| 约束 | 内容 |
|---|---|
| 发布形态 | 不发布、不签名（ad-hoc `CODE_SIGN_IDENTITY = "-"`）、不公证、无更新通道 |
| Bundle ID | `local.FlowTrace`（重命名前为 `local.iTrafficPlus`） |
| 部署目标 | macOS **11.0**（上游为 10.15，本分支抬高以换取 `Logger` / `@StateObject` 免标注） |
| 权限 | 无沙箱扩展、无 `NetworkExtension`、entitlements 为空 `<dict/>` |
| 网络请求 | **零**。上游「只在点击时发一次 GitHub 更新检查」的规则在本分支被强化为「任何情况下都不发请求」 |
| 依赖 | 零第三方包；SQLite 用系统 `import SQLite3` |
| 应用形态 | 菜单栏应用（`Info.plist` 中 `LSUIElement = true`），popover 式界面 |

底层能力边界：因为仍是用户态 `nettop`，**无法**做按域名/连接的归因，也做不到 NetworkExtension 那种精确的每接口归属。这是刻意保留的架构选择。

---

## 2. 技术栈

| 层 | 选型 | 说明 |
|---|---|---|
| 语言 | Swift 5.0（`SWIFT_VERSION = 5.0`） | |
| UI | SwiftUI 为主 + AppKit 补位 | 无 Charts 框架（需 macOS 13）；所有图表用 `Path` / 矩形手绘 |
| 响应式 | Combine（`@Published` + `sink`） | 见第 8 节「Combine 陷阱」 |
| 持久化 | 系统 SQLite3（WAL + `synchronous=NORMAL`） | 单文件库 + 私有串行队列 |
| 进程调用 | `Foundation.Process` 驱动 `/usr/bin/script` → `/usr/bin/nettop` | |
| 通知 | `UserNotifications`（本地通知） | |
| 登录项 | `ServiceManagement.SMAppService`（macOS 13+） | 11–12 报 `.unsupported` |
| 构建 | XcodeGen（`project.yml` 为唯一事实来源） | `FlowTrace.xcodeproj` 由 `xcodegen generate` 生成 |

---

## 3. 整体架构

### 3.1 分层视图

```
┌──────────────────────────────────────────────────────────────┐
│  采集层 (Service + Feature/Interface)                        │
│   NettopRunner (per-process)      InterfaceMonitor (socket)  │
│        │ onFrame                        │ onAggregate        │
├────────┼────────────────────────────────┼────────────────────┤
│  解析 / 归一化层 (Network.swift)        │                    │
│   parser(): 唯一一处 delta ÷ interval   │                    │
│   handleFrame(): 分发到各消费者         │                    │
├─────────────────────────────────────────┼────────────────────┤
│  内存状态层 (SharedStore 单例)          ▼                    │
│   HistoryStore / StatusDataModel / InterfaceModel            │
│   ListViewModel / UsageAggregator / InterfaceMinuteAggregator │
│   ProcessUsageAggregator / QuotaMonitor / ProcessAlertMonitor │
├──────────────────────────────────────────────────────────────┤
│  持久化层 (HistoryPersistence, SQLite)                        │
│   history / interface_history / interface_minute /            │
│   process_usage / process_alert                               │
├──────────────────────────────────────────────────────────────┤
│  展示层                                                       │
│   popover: ContentView(+StatusBarView 菜单栏)                 │
│   SettingsRootView（独立 NSWindow）                           │
│   HistoryWindowView（独立 NSWindow，3 个 tab）                │
└──────────────────────────────────────────────────────────────┘
       横切：Appearance(强调色) · Localization(多语言) · Logging
```

### 3.2 关键设计原则

1. **归一化只发生一次。** `nettop` 以 `-d`（delta）模式、`-s interval` 采样，一帧报的是整个采样窗口的字节数。`Network.parser` 是**唯一**做 `÷ interval` 的地方（`ProcessEntity.inBytesPerSec` 字段名自带单位）。下游任何地方再除一次，就会复现上游 issue #28（列表比菜单栏大一倍）。
2. **单例容器集中装配。** 所有跨界面存活的 `ObservableObject` 都挂在 `enum SharedStore`（`Store.swift`）上，由 `AppDelegate` 在启动期接线。
3. **每帧主线程分发。** 子进程 I/O 在自己的串行队列，帧解析在回调线程，但所有 `@Published` 写入统一切到主队列（`Network.handleFrame` 内的 `DispatchQueue.main.async`）。
4. **模块自洽。** `FlowTrace/Feature/<Name>/` 下每个模块自带视图、模型与纯函数工具，并通过 `project.yml` 的 path 通配自动进入 target。
5. **退化可用。** SQLite 打开失败时 `SharedStore.historyPersistence` 为 `nil`，各功能降级为纯内存运行并记 error 日志，不阻塞启动。

---

## 4. 目录与文件说明

### 4.1 顶层

```
FlowTrace/
├── AGENTS.md               仓库工作约定 +「Active experiments」功能台账（改动上游文件的必须登记在此）
├── README.md               项目简介与构建方式
├── LICENSE
├── project.yml             XcodeGen 源定义（唯一构建事实来源）
├── FlowTrace.xcodeproj/    由 project.yml 生成
├── changelog/0.3.0.md      本分支逐 milestone 的变更记录（最完整的特性演进史）
├── docs/ARCHITECTURE.md    本文档
├── FlowTrace/              分支自有代码（Feature 模块）
├── FlowTraceTests/         单元测试 target
├── FlowTraceForMac/        上游继承的应用主干源码 + 资源
└── .trellis/               工作流（脚本、agents、tasks、spec）；spec/ 见下文 4.8

### 4.8 `.trellis/spec/` — 项目规范（仅 macOS）

> Trellis agent 与新维护者的入口；2026-09 经过一次结构性整理，去掉了不
> 适用的 web 模板占位文件。**所有 macOS Swift 相关规范都在此目录下。**

| 路径 | 主题 |
| --- | --- |
| [`index.md`](../../.trellis/spec/index.md) | 顶层索引；必读 |
| `macos/index.md` | 项目描述 + 5 个子规范索引 + Hard Rules |
| `macos/project-layout.md` | `FlowTraceForMac/` 与 `FlowTrace/Feature/<Name>/` 的边界、target 接线、import 规则、与 AGENTS.md 的仲裁 |
| `macos/swiftui-conventions.md` | `@StateObject` vs `@ObservedObject`、accent scope、AppKit bridge、`lineLimit` + `minimumScaleFactor` |
| `macos/combine-pitfalls.md` | `@Published` willSet race、deferred UI update、locale 桥接 staleness |
| `macos/localization.md` | `Loc.l` 与 `Loc.dateFormatter`、`setLocalizedDateFormatFromTemplate` 顺序陷阱、机器用时间戳例外 |
| `macos/persistence.md` | SQLite schema、串行队列、两套时间基准（`ts` epoch-ms vs `minute_bucket` 本地分钟序数）、三条清理路径 |
| `guides/index.md` | 思考指南索引 |
| `guides/code-reuse-thinking-guide.md` | 重复模式识别 |
| `guides/cross-layer-thinking-guide.md` | 跨层数据流陷阱 |
| `guides/swift-combine-swiftui-pitfalls.md` | Combine 坑点长文（与 `macos/combine-pitfalls.md` 内容重叠） |

**Trellis agents**（`agents/implement.md`、`agents/check.md`）已改写，
明确引导到 `macos/` 与 AGENTS.md。**AGENTS.md 仍是最终仲裁者**——当 spec
与 AGENTS.md 冲突时以 AGENTS.md 为准（agents 也按这条规则运行）。
```

### 4.2 `FlowTraceForMac/` — 应用主干

| 文件 | 职责 |
|---|---|
| `AppDelegate.swift` | 入口（`@NSApplicationMain`）。启动顺序、菜单栏 `NSStatusItem` 装配、popover 生命周期与深度休眠、设置窗/历史窗的懒创建、通知代理（前台也弹 banner/sound）、窗口标题的本地化刷新 |
| `ContentView.swift` | popover 根视图：头部（图标 + 名称 + 上游链接 + ⚙ + 退出）→ 搜索栏 → 排序表头 → 进程列表 → 接口概览 → 历史 sparkline。含 `ProcessRow` |
| `StatusBarView.swift` | 菜单栏内容：固定宽度两列 —— 速率列（49pt：↙/↗ + 速率）与总量列（38pt：`D`=今日、`P`=当前配额周期）。宽度常量与 `AppDelegate.statusBarLength` 必须保持一致 |
| `MenuItem.swift` | 头部的小文本按钮（Quit / Upstream） |
| `Network.swift` | **帧管线中枢**。`handleFrame` 把一帧喂给 `ProcessUsageAggregator` / `UsageAggregator.tick` / `ProcessAlertMonitor`，再在主队列写 `HistoryStore`、`StatusDataModel`、`ListViewModel`。含 `parser`（唯一归一化点）与 `tryToMakeAppSleepDeep`（30 帧无交互后释放 popover controller） |
| `Store.swift` | `enum SharedStore`：全部单例 + `attachHistoryPersistence(_:)` + `View.withGlobalEnvironmentObjects()` |
| `ProcessEntity.swift` | 值类型：`pid / name / inBytesPerSec / outBytesPerSec / icon`（`Icon` 为 `NSImage?`） |
| `Utils.swift` | `formatBytes`（带 GB 档，菜单栏用）、`formatBytesCompact`（行内紧凑格式）、`getAppInfo(pid:name:)`（PID→图标/名，未命中时向上走最多 6 层父进程）、`getAggregatedAppInfo(name:)`（按名查图标，**绝不可传 pid 0**）、两个带 3600s TTL 的缓存字典 |
| `Model/ListViewModel.swift` | 进程列表 VM：`items` / `searchText` / `sortMode` / `todayUsage`，`updateData` 做 PID 级增量更新，`mergeSameNameProcesses` 同名合并，`sort(items:mode:)` 纯函数比较器，`trackTodayUsage` 维护「今日累计 = 磁盘 base + 本次会话增量」 |
| `Model/StatusDataModel.swift` | 菜单栏速率：`totalInBytesPerSec` / `totalOutBytesPerSec` |
| `Model/GlobalModel.swift` | 跨界面状态：`viewShowing` / `controllerHaveBeenReleased` / `isSleepDeep` |
| `Service/NettopRunner.swift` | 驱动 `/usr/bin/script -q /dev/null /usr/bin/nettop -P -d -L 0 -J bytes_in,bytes_out -t external -s <n> -c`；私有串行队列；行缓冲 + 防抖成帧；**丢弃首帧**（首帧是启动以来累计值）；进程终止后 0.5s 自动重启 |
| `Info.plist` | `LSUIElement=true`（纯菜单栏应用）、`NSMainStoryboardFile=Main` |
| `FlowTraceForMac.entitlements` | 空字典（不扩权） |
| `Base.lproj/Main.storyboard` | 上游遗留的空壳 storyboard 资源 |
| `Assets.xcassets/` | AppIcon、`ContentBGColor`（popover 背景色）、logo 等 |
| `*.lproj/Localizable.strings` | 21 种语言的字符串表（见 4.5） |

> `NettopRunner` 的两个「非显而易见」注意点（上游继承）：必须用 `script` 包一层伪 TTY，且必须**持住 stdin pipe 不关闭**，否则 nettop 的 TUI 循环会 100% 空转 CPU。

### 4.3 `FlowTrace/Feature/` — 分支自有模块

#### Appearance（强调色子系统）

| 文件 | 职责 |
|---|---|
| `AccentColor.swift`（约 406 行） | `AccentSource`（`.system` / `.custom`）、`AccentColorManager`（唯一真相源，UserDefaults key：`ft.accent.source`、`ft.accent.hex`，新装默认 custom + `#00CFFF`）、`AccentHexField`、`\.appAccent` 环境值、`View.appAccentScope(_:)`（每个窗口根唯一应用点，同时 `.tint`（12+）/`.accentColor`（11）并发布环境值）、`animationIdentity`（系统模式下属常量，避免无意义淡入） |
| `AccentControls.swift`（约 591 行） | 为「AppKit 绘制的表面无法跟随自定义强调色」而手绘的控件：`AccentTextField`（无边框原生编辑 + 自绘聚焦环 + 改写 `selectedTextAttributes` 的文本选区色）、`AccentPicker`（下拉）、`AccentDateField`（本地化月历，设置页与历史窗三个范围过滤器共用）、`accentFieldChrome(isFocused:)` |

系统强调色实时跟随：监听分布式通知 `AppleColorPreferencesChangedNotification`，收到后 `systemAccentRevision &+= 1` 触发重绘。`systemAccentColor` 必须手动解析成具体 sRGB 分量（直接包 `NSColor.controlAccentColor` 在桥接表面会解析错误）。

#### History（历史数据与可视化）

| 文件 | 职责 |
|---|---|
| `RingBuffer.swift` | 泛型定长环形缓冲，预分配数组，append O(1) 不分配 |
| `HistoryStore.swift` | popover sparkline 的数据源。`capacity = 60`；`samples: [HistoryFrame]` + `summary: HistorySummary`（今日峰值 / 24h 均值 / 今日累计）；`bootstrap()` 从磁盘回填最近 60 帧（重启后曲线不空）；`append` 同时发布内存快照并落库 |
| `HistoryView.swift` | popover 底部 60 采样 sparkline（上下两条 `Path`：in 在基线之上、out 在下）+ 峰值/均值 + 打开历史窗按钮 |
| `HistoryWindowView.swift` | 历史窗口根视图，三个 tab：`appUsage`（默认）/ `heatmap` / `alerts`；`.appAccentScope` 在此应用；窗口 680×560 |
| `AppUsageView.swift` | 「App usage」页：范围内每进程累计 ↓/↑/合计，可排序、可导出 CSV |
| `ProcessUsageModel.swift` | 上述页面的 VM：`HeatmapRange` 范围 + `rangeBuckets` 本地分钟桶换算 + 排序 |
| `HistoryHeatmapView.swift` | 热力网格：`dayPerRow`（每天一行 24 列，带行末 Σ）/ `dayPerColumn`（GitHub 风格）；颜色深浅 = (in+out) 相对最忙格子的占比；hover 显示明细 |
| `HistoryHeatmapModel.swift` | 热力图 VM：范围、`selectedCategories`、`cells`、`reload()`、`exportCSV()` |
| `AlertLogView.swift` | 「Alert log」页：`AlertRange`（all/today/7d/30d/custom）+ `AlertSortMode`（time/name/direction/today/median/factor），内存内排序不查库 |
| `ProcessUsageAggregator.swift` | 把每帧进程速率滚入**本地分钟桶**，跨分钟时 flush 成 `bytes = Σ(rate) × interval` 写入 `process_usage`；用 `seenPids` 丢弃每个新 pid 的首帧（否则会把进程启动以来的累计流量灌进桶里） |
| `CSVExporter.swift` | 三种 CSV 形状（process / interface / alert）+ `NSSavePanel`；字节导出为纯数字，单位写在表头 |
| `HistoryPersistence.swift`（约 433 行） | SQLite 门面：连接打开 / schema / 保留期清理 / 写入路径。详见第 6 节 |
| `HistoryPersistenceModels.swift` | 持久化层的全部数据模型 struct：`HistoryRow`、`InterfaceHistoryRow`、`HeatmapCell`、`ProcessUsageSummary`、`ProcessUsageFlushRow`、`ProcessAlertRow`、`AlertRecord` |
| `HistoryPersistence+Queries.swift` | 只读查询扩展（各表聚合、`export*` 的读路径）。为了让 extension 能共享同一个 SQLite 句柄与串行队列，`db` / `queue` / `SQLITE_TRANSIENT_BRIDGE` 已由 `private` 放宽为 internal（同模块同 target，未外泄） |

#### Interface（接口维度）

| 文件 | 职责 |
|---|---|
| `InterfaceClassifier.swift` | `InterfaceCategory`（`Wi-Fi` / `Wired` / `Local Direct` / `Other`，rawValue 即显示名且作为落库值）。运行 `/usr/sbin/networksetup -listallhardwareports` 解析 `Hardware Port` ↔ `Device` 映射；命中硬件表优先，未命中用名称启发式（`awdl0`/`llw0`→Local Direct，数字 `en*`→Wired，`bridge*`/未知→Other）。纯函数、可单测 |
| `InterfaceMonitor.swift` | **第二个独立 nettop 进程**，socket 模式：`-d -L 0 -J bytes_in,bytes_out,interface -t external -s <n> -c`（无 `-P`，多 `interface` 列）。解析时**跳过 interface 列为空的行**（那是进程汇总行，会把数字翻倍）。`onAggregate` 在主队列回调 |
| `InterfaceModel.swift` | popover 接口概览的数据源：最新 `snapshot` + `todayUsage`（磁盘 base + 本次会话增量，跨午夜重置） |
| `InterfaceMinuteAggregator.swift` | 把每帧接口快照滚入本地分钟桶并写 `interface_minute`（与 `ProcessUsageAggregator` 同一分桶约定） |
| `InterfaceSummaryView.swift` | popover 中的四桶堆叠条 + 图例 |

#### Localization

| 文件 | 职责 |
|---|---|
| `LocalizationManager.swift` | `Loc`（`Loc.l(_:table:)` 全 app 唯一取字符串入口、`Loc.appDisplayName`、`Loc.dateFormatter(template:locale:)` 供一切用户可见日期使用）+ `LocalizationManager.shared`。<br>支持「跟随系统」与 `languageOverride` 覆盖；自己定位 `.lproj` Bundle 读取（SwiftUI 的 `Text("key")` 只会查主 bundle，无法支持运行时切换）；`lprojBundle(for:in:)` 走两条查找（`path(forResource:ofType:)` → 资源目录拼路径 + 存在性检查），避免单一 API 落空后静默回退到系统语言；缺 key 用哨兵值判定并回退主 bundle，最终回退显示 key 本身 |

#### Logging

| 文件 | 职责 |
|---|---|
| `AppLogger.swift` | `AppLogger`：subsystem `local.FlowTrace` + 7 个 `Logger` 分类。`LogFileSink`：写 `~/Library/Logs/FlowTrace.log`（Debug 默认开，或用环境变量 `ITRAFFICPLUS_FILE_LOG=1`），串行队列异步追加 |
| `LogHelpers.swift` | `Log.<category>` 帮助器，**唯一推荐的打日志入口**：同一行同时写 `os.Logger` 与文件 sink |

双 sink 的原因（原文）：macOS 11+ 对 **ad-hoc 签名**应用的 `os.log` 施加隐私过滤，日志可在 Console.app「Now」面板看到但**不落盘**，`log show` 读不回来；文件 sink 不受 logd 隐私过滤影响，可 `tail -f`。

分类名（同时是 `Log` 与 `AppLogger` 的属性名）：`appDelegate`、`network`、`nettopRunner`、`persistence`、`settings`、`interface`、`l10n`。

#### Search

| 文件 | 职责 |
|---|---|
| `SearchFilter.swift` | 纯函数 `filter(items:searchText:)`：名称 `lowercased().contains`（恒定大小写不敏感，已无配置项）+ PID 精确匹配；空搜索串原样返回 |
| `ProcessSearchBar.swift` | 单行 `TextField`（绑定 `ListViewModel.searchText`）+ `⌕` 字形 + `×` 清除按钮。**刻意保留平台 `TextField`**，其文本选区跟随系统强调色（AGENTS.md 记录的例外），过滤逻辑不在此处 |

#### Settings

| 文件 | 职责 |
|---|---|
| `SettingsStore.swift`（约 381 行） | `ObservableObject` over `UserDefaults.standard`，20 个持久化 key 集中定义（见第 7 节）。含一次性迁移：旧域 `local.iTrafficPlus` 全量复制、旧 key 重命名（`showMonthInMenuBar`→`showPeriodInMenuBar`）。`applyAppearance()` 把外观映射到 `NSApp.appearance` 并额外钉住被缓存的 popover 窗口 |
| `SettingsView.swift`（约 246 行） | `SettingsTab`（`general / quota / alerts / storage / about`）、`SettingsMetrics`（`width 480 / padding 20 / tabBarHeight 66 / controlWidth 200`）、`SettingsTabSelection`、`SettingsRootView`、手绘 `SettingsTabBar` / `SettingsTabButton`、`SettingsPanes`（按 tab 分发到下面的 pane 文件） |
| `SettingsComponents.swift` | 跨 pane 共用的构件：`SettingsPane`（每个 pane 是独立 SwiftUI root，**必须各自 `.appAccentScope`**）、`SettingsRow` / `SettingsNote` / `SettingsSwitch`、`EditableNumberField`、`AccentTimeField` |
| `Settings{General,Quota,Alerts,Storage,About}Pane.swift` | 每个 `SettingsTab` 一个文件。这些 pane 原先是 `SettingsView.swift` 内部的 private 类型，随文件拆分提升为 internal |
| `DataCleaner.swift` | `resetInMemory()`：依次重置 historyStore / usageAggregator / interfaceModel / interfaceMinuteAggregator / processAlertMonitor / quotaMonitor。磁盘侧删除由 Settings 窗口经 `HistoryPersistence.deleteRange` 完成 |
| `DataRetentionController.swift` | 每日保留期检查点：60s Timer 轮询「配置的时间点是否已过且今天是否已执行」，按 `cleanupMode` 自动删除或发提醒；对睡眠/唤醒与时钟变更天然健壮 |
| `LaunchAtLoginManager.swift` | 登录项：13+ 用 `SMAppService.mainApp.register/unregister`，11–12 报 `.unsupported`；`ensureRegisteredAfterRename()` 处理 iTrafficPlus→FlowTrace 的 bundle id 迁移 |

#### Usage

| 文件 | 职责 |
|---|---|
| `UsageAggregator.swift` | 周期用量积分器：`UsageBytes`（in/out/total）+ `today/week/month` + `bytes(forPeriod:)`。`tick()` 由帧路径调用、内部节流（默认 2s）。菜单栏 `P` 段与 `QuotaMonitor` 共用此单一口径 |
| `QuotaMonitor.swift` | 配额阈值监视：订阅 `aggregator.$today/$week/$month`，阈值集合 `{80, 100, 自定义}`；跨越检测 `prev < t && current >= t`（已提取为静态纯函数 `shouldFire(...)` 以便单测）；去重 key `"<周期起始日>:<阈值>"` 存 UserDefaults `quotaFiredKeys`，周期滚动后自动重置。含 `ByteFormatter` |
| `ProcessAlertMonitor.swift` | 按进程的异常流量告警：方向独立，需同时满足「今日累计 ≥ 绝对下限（MB）」与「超过该进程 7 日日中位数 × 倍数」；基线为 0 视为「任何流量都异常」。**每进程每方向每自然日最多一条**，去重由 `process_alert` 表的唯一索引 `(day, name_key, direction)` 承担（重启也天然保持）。`decide(...)` 为纯函数 |

### 4.4 `FlowTraceTests/`

| 文件 | 覆盖内容 |
|---|---|
| `ListViewModelSortTests.swift` | `ListViewModel.sort` 的各比较器、并列时的名称次序、空/单元素、幂等性 |
| `ListViewModelMergeTests.swift` | `mergeSameNameProcesses` 的同名合并语义 |
| `QuotaMonitorTests.swift` | 阈值集合构造、`limitBytes` 换算与下限钳制、跨阈值判定（`shouldFire`，含同帧跨多档与周期滚动重新武装）、`periodStartKey`、fired-key 的 UserDefaults 往返 |
| `ProcessUsageAggregatorTests.swift` | 端到端：分钟桶稳定性、同名跨 pid/大小写合并、`bytes = Σ(rate) × interval`、零流量跳过、flush 后不重复累加（回归）、范围查询 `[from, to)`、排序模式 |
| `HistoryHeatmapPersistenceTests.swift` | 端到端：`interface_minute` 按本地小时桶 SUM 聚合、类别过滤不泄漏、空范围、跨午夜分日 |
| `LocalizationTests.swift` | 21 种语言的 `.lproj` 是否都在构建产物里、能打开、且取得到已知 key；`Bundle.main` 查找路径（运行时实际走的）覆盖全部语言；中英文不会解析到同一张表；`resolveLocale` 的覆盖 / 跟随系统行为 |
| `AccentDateFieldTests.swift` | 手绘日期控件的星期表头是否跟随**请求的**语言而非系统语言（`en` 必须得到 `S M T W T F S`）；表头按各语言的周首日轮转、且是本周符号的一个纯重排 |

前两个是纯函数测试；后三个走真实依赖——`SettingsStore(defaults:)` 与 `QuotaMonitor(settings:aggregator:defaults:)` 都可注入，各自使用独立的 `UserDefaults` suite；持久化测试使用临时目录里的 SQLite 库（含 WAL 边车文件，`tearDown` 一并删除）。测试**不会**写入用户的真实设置或历史库。

### 4.5 本地化资源（`FlowTraceForMac/*.lproj/`）

21 种语言各含一份 `Localizable.strings`：
`en`、`zh-Hans`、`zh-Hant`、`es`、`pt-BR`、`fr`、`de`、`it`、`ru`、`ja`、`ko`、`vi`、`hi`、`bn`、`ur`、`pa`、`mr`、`ta`、`jv`、`ar`、`fa`。
其中 `zh-Hans` 与 `zh-Hant` 额外含 `InfoPlist.strings`。

`project.yml` 把全部 `.lproj` 从 `sources` 里排除，再逐个以 `buildPhase: resources` 显式声明（否则生成器不会把它们当资源打包）。

### 4.6 曾经的 `scripts/verify_*.swift`（已转写并删除）

仓库根目录曾有一组独立 CLI 校验脚本（`swift verify_xxx.swift` 直接跑，不参与构建），其存在理由是「`xcodebuild test` 跑不起来」。这个理由已不成立：

- 真实障碍是 `PRODUCT_NAME` 冲突 + 测试断言在 `ListSortMode` 改名后未同步（见 9.2），两者都已修复；
- 脚本内嵌的是被测逻辑的**镜像副本**，而且**已经漂移**——`verify_process_usage.swift` 没有镜像 `ProcessUsageAggregator.seenPids` 的首帧丢弃逻辑，所以它断言的语义与真实实现不一致，却仍然「通过」。

因此这 3 个脚本的断言已于 2026-09 全部转写为真正的 XCTest（`@testable import FlowTrace`，直接调用真实类型），脚本本身已删除。转写后的覆盖范围见 4.4 与 9.3。

### 4.7 `.trellis/`

工作流与规范目录，与产品代码无关：

- `spec/`——项目规范（详见 4.8）。
- `tasks/`——PRD、实现记录、归档。
- `scripts/`——工作流脚本（`task.py`、`add_session.py` 等）。
- `workspace/`——研究笔记。
- `agents/`——Trellis 子 agent 的 prompt 模板（`implement.md`、`check.md`）。
- `workflow.md`、`config.yaml`——运行时配置。

---

## 5. 运行时数据流

### 5.1 启动顺序（`AppDelegate.applicationDidFinishLaunching`）

顺序不可调换，各步原因如下：

1. 记启动日志（含日志文件路径）。
2. `LaunchAtLoginManager.ensureRegisteredAfterRename()` —— 处理改名后的登录项身份。
3. 注册 `UNUserNotificationCenter` 代理，`willPresent` 返回 `[.banner, .list, .sound]`（菜单栏应用几乎总是「前台」，不实现此方法就只能进通知中心，没有横幅）。
4. **先把 SQLite 接上**：按 `SettingsStore.historyRetentionDays` 算保留期 → `HistoryPersistence(...)` → `SharedStore.attachHistoryPersistence(_:)`（内部重建带持久化的 `HistoryStore(capacity: 60, persistence:)` 并 `bootstrap()`）→ `processAlertMonitor.bootstrap()`。**必须早于 `Network.startListenNetwork()`**，否则启动后的头几帧只进内存、不落盘。
5. 构造 `ContentView` / `StatusBarView` / `Network`，装配菜单栏 `NSStatusItem`，并按设置项计算状态栏宽度。
6. 订阅语言变更，刷新已缓存窗口的标题。
7. `network.startListenNetwork()` —— 同时拉起 `NettopRunner` 与 `InterfaceMonitor`。
8. `DataRetentionController.shared.start()` —— 每日保留期检查点。

### 5.2 每帧管线（进程维度）

```
NettopRunner.flushFrame()  ──onFrame([String])──▶  Network.handleFrame
   （丢首帧）
        │
        ├─ 逐行 parser()：bytes_in/out ÷ interval   ← 唯一归一化点
        │     累计 totalInRate / totalOutRate（菜单栏用）
        │
        ├─ usageAggregator.feed(entities:)      → 本地分钟桶（跨分钟落 process_usage）
        ├─ SharedStore.usageAggregator.tick()   → 节流查库，刷新 today/week/month
        ├─ processAlertMonitor.feed(...)        → 异常流量判定（节流 60s）
        │
        └─ DispatchQueue.main.async {
               historyStore.append(totalIn, totalOut)      ← 先写，sparkline 与菜单栏看到同一份数
               statusDataModel.update(...)                  ← 菜单栏
               listViewModel.trackTodayUsage(...)           ← 今日累计（base + session）
               viewModel.updateData(newItems:)              ← 列表（PID 增量合并 + 排序）
           }
```

### 5.3 每帧管线（接口维度）

`InterfaceMonitor.onAggregate(InterfaceSnapshot)` 回调内依次：

1. `interfaceModel.update(snapshot)` —— popover 实时快照（值未变则不发布）。
2. `interfaceModel.trackTodayFrame(snapshot)` —— 今日累计（磁盘 base + 帧增量）。
3. `interfaceMinuteAggregator.feed(...)` —— 本地分钟桶 → `interface_minute`（供热力图）。
4. 把快照的窗口增量 `÷ interval` 组装成 `[InterfaceHistoryRow]` → `appendInterface(...)` → `interface_history`（供今日 base 与热力图的旧数据）。

> 第 4 步的除法同样只发生一次，理由与 5.2 相同（issue #28）。

### 5.4 界面组织

| 界面 | 宿主 | 说明 |
|---|---|---|
| 菜单栏 | `NSStatusItem.button` + `NSHostingView(StatusBarView)` | 宽度由 `AppDelegate.statusBarLength` 按设置项算出：`6 + (49 若有速率) + (4 间隔 若两列都有) + (38 若有总量)`，最小 40pt |
| popover | `NSPopover`（340×520，`behavior = .transient`）+ `NSHostingController(ContentView)` | 缓存复用。30 帧无交互后 `tryToMakeAppSleepDeep` 会释放 controller 并置 `controllerHaveBeenReleased`，下次点击时重建 |
| 设置窗 | 懒创建 `NSWindow` + `NSHostingController(SettingsRootView)` | 复用同一窗口；切换 pane 时按 `SettingsMetrics.tabBarHeight + tab.contentHeight` 调整高度并保持顶边 |
| 历史窗 | 懒创建 `NSWindow` + `NSHostingController(HistoryWindowView)` | 680×480 起，可缩放；三个 tab |

---

## 6. 持久化：`HistoryPersistence`

### 6.1 位置与打开参数

- 路径：`~/Library/Application Support/FlowTrace/history.sqlite3`
- **一次性目录迁移**：若检测到旧的 `.../Application Support/iTrafficPlus/` 目录，整体 `moveItem` 到 `FlowTrace/`，保住历史与设置。
- 打开标志：`SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX`
- PRAGMA：`journal_mode = WAL`、`synchronous = NORMAL`

### 6.2 表结构

| 表 | 字段 | 索引 |
|---|---|---|
| `history` | `id` PK, `ts`(epoch ms), `in_bps`, `out_bps` | `idx_history_ts(ts)` |
| `interface_history` | `id`, `ts`, `category` TEXT, `in_bps`, `out_bps` | `idx_iface_ts_cat(ts, category)` |
| `interface_minute` | `id`, `minute_bucket` INT, `category` TEXT, `in_bytes`, `out_bytes` | `idx_ifmin_bucket_cat(minute_bucket, category)` |
| `process_usage` | `id`, `minute_bucket` INT, `name` TEXT, `name_key` TEXT, `in_bytes`, `out_bytes` | `idx_pu_minute(minute_bucket)` |
| `process_alert` | `id`, `day` INT, `name`, `name_key`, `direction` TEXT, `today_bytes`, `baseline_bytes`, `multiplier` REAL, `ts` | **UNIQUE** `idx_alert_unique(day, name_key, direction)` |

两套时间基准并存，务必区分：

- `ts` = epoch 毫秒（帧级表 `history` / `interface_history`）。
- `minute_bucket` = **本地分钟序号**，即 `(epochMs + 本地时区偏移ms) / 60000`（分钟级表 `process_usage` / `interface_minute`）。`ProcessUsageAggregator.bucket(of:)`、`InterfaceMinuteAggregator.minuteBucket(_:)`、`ProcessUsageModel.rangeBuckets` 三处共用此约定，缺一不可对齐。

### 6.3 线程模型

- 单个私有串行队列 `DispatchQueue(label: "history-persistence", qos: .utility)` 独占全部 `sqlite3_*` 调用；**主线程从不触碰 SQLite**。
- 写方法（`append` / `appendInterface` / `appendInterfaceMinute` / `appendProcessUsage` / `appendProcessAlert`）立即返回，实际写在队列上执行。
- 读方法默认 `queue.async` 查询后回主队列回调；唯一同步读是 `recent(limit:)`——有界、走索引，且只在启动期调用。

### 6.4 保留与清理（三条不同路径，范围各不相同）

| 触发 | 方法 | 覆盖表 |
|---|---|---|
| 启动时一次 | `prune()`（按 `retentionSeconds`） | `history`、`interface_history`、`process_usage`、`interface_minute`（**不含** `process_alert`） |
| 每日检查点（自动模式） | `pruneExpired(cutoffMs:cutoffBucket:)` / `expiredRowCount(...)` | `ts` 组：`history`、`interface_history`、`process_alert`；桶组：`process_usage`、`interface_minute` |
| 用户手动 | `clearAllTables(completion:)`（5 表），`deleteRange(fromMs:toMs:fromBucket:toBucket:)` / `countRange(...)`（4 表） | 见左 |

默认保留期 7 天，实际值由 `SettingsStore.historyRetentionDays`（默认 30）在启动时传入。

### 6.5 查询 API 一览

| 方法 | 数据源 | 消费方 |
|---|---|---|
| `recent(limit:)`（同步） | `history` | `HistoryStore.bootstrap()` |
| `summary(dayStart:completion:)` | `history` | `HistoryStore.refreshSummary()`（每帧一次、值变才发布） |
| `historyUsageBytes(fromMs:toMs:completion:)` | `history` | `UsageAggregator`（今日/本周/本月总量） |
| `interfaceMinuteHeatmap(fromMs:toMs:categories:completion:)` | `interface_minute` | `HistoryHeatmapModel.reload()` |
| `interfaceUsageBytes(fromMs:toMs:interval:completion:)` | `interface_history`（速率 × interval） | `InterfaceModel.loadTodayBase()` |
| `processUsage(fromBucket:toBucket:completion:)` | `process_usage` | `ProcessUsageModel.reload()`、`ListViewModel.loadTodayBase()` |
| `exportProcessUsage(...)` / `exportInterfaceMinute(...)` | 分钟表 | 两个 `exportCSV()` |
| `alertRecords(fromMs:limit:completion:)` | `process_alert` | `AlertLogModel.reload()` |
| `todayProcessTotals(fromBucket:completion:)` / `dailyProcessTotals(fromBucket:toBucket:completion:)` | `process_usage` | `ProcessAlertMonitor` 的今日量与 7 日基线 |
| `appendProcessAlert(_:completion:)` | `process_alert` | `ProcessAlertMonitor`（唯一索引命中时 `inserted == false`，即「今日已告警」） |
| `static date(fromLocalMinuteBucket:)` | — | 分钟序号还原本地 `Date`，导出用 |

---

## 7. 配置项：`SettingsStore`

存储于 `UserDefaults.standard`（可用 `defaults read local.FlowTrace` 直接查看）。20 个 key：

| key | 属性 | 默认值 | 说明 |
|---|---|---|---|
| `launchAtLogin` | `launchAtLogin` | 取 **OS 实时状态** | 以系统登录项为权威，避免与「系统设置」里的改动漂移 |
| `defaultSortModeRaw` | `defaultSortModeRaw` | `"download"` | 会话级生效（下次启动才应用） |
| `appearanceRaw` | `appearanceRaw` | `"system"` | system / light / dark |
| `showDownloadInStatusBar` | 同名 | `true` | 菜单栏 ↙ |
| `showUploadInStatusBar` | 同名 | `true` | 菜单栏 ↗ |
| `historyRetentionDays` | 同名 | `30` | 历史保留天数 |
| `cleanupMode` | `cleanupModeRaw` | `"manualNotification"` | 自动清理 / 到期提醒 |
| `retentionTimeOfDay` | 同名 | `43200`（12:00） | 每日检查点时间（秒） |
| `languageOverride` | 同名 | `nil` | nil = 跟随系统 |
| `quotaEnabled` | 同名 | `false` | |
| `quotaPeriod` | 同名 | `"month"` | day / week / month |
| `quotaLimitGB` | 同名 | `100` | |
| `quotaCustomPercent` | 同名 | `0` | 0 表示不启用自定义阈值（80/100 恒开） |
| `showTodayInMenuBar` | 同名 | `false` | 菜单栏 `D` 段 |
| `showPeriodInMenuBar` | 同名 | `false` | 菜单栏 `P` 段 |
| `uploadAlertEnabled` | 同名 | `false` | |
| `alertDownloadMultiplier` | 同名 | `10` | |
| `alertUploadMultiplier` | 同名 | `10` | |
| `alertMinDownloadMB` | 同名 | `500` | 绝对下限 |
| `alertMinUploadMB` | 同名 | `500` | 绝对下限 |

**不由 `SettingsStore` 拥有的 key**：

- `ft.accent.source` / `ft.accent.hex` —— `AccentColorManager`
- `quotaFiredKeys` —— `QuotaMonitor` 直接读写
- 非持久化：`refreshInterval` 是 `let = 1`（固定 1s，UI 已取消该选项）

写入路径统一用 `$prop.dropFirst().sink { ... }`，而**不用 `didSet`**——`didSet` 会在 init 的播种赋值阶段触发，把磁盘上已有的值再写回一遍并产生虚假的「用户改过」日志。

---

## 8. 工程约定与已知陷阱

### 8.1 构建与资源

- `project.yml` 是唯一事实来源，改完必须 `xcodegen generate` 并同时提交 YAML 与生成的工程。
- 两个 target：应用 `FlowTrace`（`MACOSX_DEPLOYMENT_TARGET = 11.0`）与单测 `FlowTraceTests`（`bundle.unit-test`，`TEST_HOST` 指向应用）。
- `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`；**刻意不设** `GLOBAL_ACCENT_COLOR_NAME`——一旦指向内置的 `AccentColor.colorset`（硬编码 `#00CFFF`），它在启动时就会成为 AppKit 控件强调色并覆盖根部的 `.tint(nil)`，导致「跟随系统」分支永远无法回落到 macOS 强调色。
- Release 开 `ENABLE_HARDENED_RUNTIME`（公证需要），签名仍保持 ad-hoc，因此全新 clone 无需证书即可构建。

### 8.2 代码约定

- **速率字段自带单位**（`inBytesPerSec` / `totalInBytesPerSec`），归一化只在 `Network.parser` 发生一次。
- **`.help(_:)` 需 `#available` 守卫**（macOS 11+），不要为它抬高部署目标。
- **SF Symbols 用 `.font` 缩放，禁止 `.resizable()`**；菜单栏尺寸下小号图标优先用 Unicode 字形（如 `⌕`、`⚙`、`↗`）。
- **每个独立托管的 SwiftUI 根都要应用 `.appAccentScope`**：popover、`SettingsPane`（每个 pane 各自一个 `NSHostingController`，没有共享父级）、历史窗口。
- **`.tint` 只覆盖 SwiftUI 绘制的内容**；AppKit 绘制的语义色（`controlAccentColor`、键盘焦点环、文本选区、下拉菜单）无法通过公开 API 按应用覆盖，自定义强调色要生效必须用 `AccentControls.swift` 里的手绘控件。
- 手绘控件在字段**销毁前**必须提交编辑：三个钩子是 `controlTextDidEndEditing`、`NSControl.textDidEndEditingNotification`（`object: field`）、`NSWindow.willCloseNotification`；切 tab 时由 `SettingsTabBar.commitPendingEdit()` 先 resign。**绝不能在 `dismantleNSView` 里提交**——那里在 `NSHostingView.deinit` 内部，通过 `@Binding` 回写会触发 SwiftUI 排他性检查并 `EXC_CRASH / SIGABRT`。

### 8.3 Combine / SwiftUI 陷阱（`@Published` 发射早于写入）

`@Published` 的 `willSet` 语义意味着 sink 在属性被写入**之前**运行。已在代码中被踩到并记录：

- 排序模式：sink 内必须使用**事件携带的** mode，否则「晚一拍生效」。
- 刷新间隔：同上，且在重启子进程前先更新 `interval`，保证归一化用当前值。
- 设置窗尺寸：sink 内同步 `setFrame` 会在 SwiftUI 更新中重入 AppKit（表现为窗口变了、pane 没变），须 `DispatchQueue.main.async` 延后一个 runloop。
- 外观切换：需同样延后一拍，否则被 AppKit 合并掉（表现为「UI 落后一次选择」）。

### 8.4 数据正确性要点

- 首帧必须丢弃：`NettopRunner` 与 `InterfaceMonitor` 都各自丢弃 spawn 后的第一帧（累计值而非增量）。
- 每个新 pid 的首帧必须丢弃：`ProcessUsageAggregator.seenPids`。
- `InterfaceMonitor` 必须跳过 interface 列为空的行，否则每项统计翻倍。
- 分钟桶累加器**无论是否写盘都要清空**——不清会让后续每次 flush 变成「自始至今的总和」（曾导致「结果远大于真实值」的 bug）。
- 按名聚合的行**绝不能调 `getAppInfo(pid: 0, ...)`**，否则所有行共用 pid 0 的缓存槽，显示成同一个名称。

---

## 9. 文档漂移与维护

本文档初稿梳理时，源码中存在 9 处「注释/文档与实现不一致」。这些已在随后的一次修订中全部修正：

| 位置 | 原描述 | 修正后 |
| --- | --- | --- |
| `README.md` / `AGENTS.md` 的 Layout 段 | 只列 `Feature/Search`、`Feature/History` | 补齐 8 个模块；应用主干目录的「carried as-is」改为「several touched by this fork」 |
| `changelog/0.3.0.md` | milestone 10/16 引用的文件已不存在 | 新增「Amendments」小节，集中标注 5 处与当前源码的分歧（不改写原始条目） |
| `HistoryView.swift` 头注释 | "deployment target is 10.15" | 11.0 |
| `HistoryWindowView.swift` 头注释 | "Two tabs" | 三个 tab（app usage / heatmap / alert log） |
| `UsageAggregator.swift` 头注释 | 读 `process_usage` 表 | 读 `history` 表（实时、节流 2s），并说明与 App-usage 页的口径差异 |
| `HistoryPersistence.swift` 头注释 | 单表 / monotonic clock / 2s cadence / debounce 清理 | 五张表、两套时间基准（epoch-ms 与本地分钟序数）、1s cadence、三条清理路径 |
| `InterfaceSummaryView.swift` 注释 | 引用不存在的 `InterfaceModel.refreshTodayUsageIfNeeded` | 改为 `trackTodayFrame` + `loadTodayBase` |
| `HistoryHeatmapModel.swift` 头注释 | 全选走 `history` 表、子集走 `interface_history` | 始终读 `interface_minute`，并说明由此损失旧数据 |
| `AppDelegate.swift` 的深休眠日志 | 直调 `AppLogger`，绕过文件 sink | 改为 `Log.appDelegate`，与「`Log.*` 是唯一推荐入口」一致 |

同一批次顺带修正的同类陈述：`AGENTS.md` 的「2-second sample」→ 1 秒、「deployment target is 10.15」与 SF Symbols 条目中的 10.15 措辞；`README.md` 的「2-second sample」以及原本只列 2 项的「What is new in this fork」。

**维护约定**：改动采样间隔、表结构、清理路径，或增删 `Feature/` 模块时，请同步检查 `README.md` 与 `AGENTS.md` 的 Layout 段，以及本文档第 4、6 节。

### 9.1 目录改名记录：`ITrafficMonitorForMac/` → `FlowTraceForMac/`

上游目录名是本仓库最后一个残留的上游命名（target 早已是 `FlowTrace`，产物 `FlowTrace.app`，bundle id `local.FlowTrace`），已统一为 `FlowTraceForMac/`。改动清单：

- 目录本身，以及 `ITrafficMonitorForMac.entitlements` → `FlowTraceForMac.entitlements`。
- `project.yml` 中 29 处路径（`sources.path`、21 个 `.lproj` 资源条目、entitlements、`DEVELOPMENT_ASSET_PATHS`、`INFOPLIST_FILE`）。
- 7 个源文件头部标记改为 `FlowTrace`（与同目录下已是 `FlowTrace` 的 `ContentView` / `Network` / `Store` / `MenuItem` 保持一致），`Main.storyboard` 内 6 处菜单标题改为 app 显示名 `FlowTrace`。
- `README.md`、`AGENTS.md` 的 Layout 段、`verify_sort.swift` / `verify_merge.swift` 的镜像说明。
- **未改动**：`.trellis/tasks/archive/` 下的历史任务归档（历史记录）；`README.md` 中 `github.com/foamzou/...` 的上游链接路径（那是上游仓库的真实目录名）。

**代价（已知并接受）**：目录名不再与上游同名，失去「一眼可辨的上游对照」；对照上游时需记住上游叫 `ITrafficMonitorForMac/`。

### 9.2 结构与卫生评审（2026-09）

一次针对目录结构与代码卫生的评审，落地如下：

| 项 | 内容 |
| --- | --- |
| 修复 `xcodebuild test` | `PRODUCT_NAME` 原在 `project.yml` 顶层 `settings.base`，对两个 target 同时生效，app 与 test 抢用同一个 `FlowTrace.swiftmodule`（`Multiple commands produce`）。已下移到各自 target；同时修正了 `ListSortMode` 改名后未同步的测试断言（`.download`/`.upload`/`.total` → `.downloadRate`/`.uploadRate`/`.todayTotal`）与 `XCTAssertEqual` 对非 `Equatable` 数组的比较。测试现在真正可跑 |
| 删除死资源 | `Assets.xcassets/AccentColor.colorset`（内容即 `#00CFFF`，无代码引用，且 `GLOBAL_ACCENT_COLOR_NAME` 刻意未设置 → 恒不生效）、`Assets.xcassets/Itraffic-logo-text.imageset`（无任何引用） |
| 删除死代码 | `DataCleaner.clearAll(completion:)`、`ProcessUsageAggregator.flush(using:)`、`HistoryPersistence.clearAllTables(completion:)` —— 三者的调用点都在功能演进中被移除，实际入口一律走 `HistoryPersistence.deleteRange` |
| 脚本归位 | 根目录 5 个 `verify_*.swift` → `scripts/` 下 3 个；`verify_sort` / `verify_merge` 与 `FlowTraceTests` 完全重复，已删除 |
| 删除无效配置 | `path: FlowTrace` 下的 `excludes: FlowTraceTests/**` —— 测试目录是仓库根的兄弟目录，该 glob 恒不匹配，注释也自相矛盾 |
| 拆分大文件 | `SettingsView.swift` 928 → 246 行（5 个 pane 各成文件 + `SettingsComponents.swift`）；`HistoryPersistence.swift` 992 → 433 行（数据模型 → `HistoryPersistenceModels.swift`，只读查询 → `HistoryPersistence+Queries.swift`） |
| 转写镜像脚本 | `scripts/` 下 3 个脚本的断言全部转写为 XCTest（新增 3 个测试文件），测试方法数 13 → 46；脚本已删除。详见 9.3 |

### 9.3 镜像脚本 → XCTest（2026-09）

`scripts/` 下的 3 个脚本内嵌的是生产逻辑的手工副本。转写后一律 `@testable import FlowTrace` 直接调用真实类型：

| 新测试文件 | 覆盖 | 来源脚本 |
| --- | --- | --- |
| `QuotaMonitorTests.swift` | 阈值集合构造、`limitBytes` 换算与钳制、`shouldFire` 跨阈值判定（同帧跨多档、周期滚动重新武装）、`periodStartKey`、fired-key 的 UserDefaults 往返 | `verify_quota.swift` |
| `ProcessUsageAggregatorTests.swift` | 分钟桶稳定性、同名跨 pid/大小写合并、`bytes = Σ(rate) × interval`、零流量跳过、flush 后不重复累加（回归）、范围查询 `[from, to)`、排序模式 | `verify_process_usage.swift` |
| `HistoryHeatmapPersistenceTests.swift` | `interface_minute` 按本地小时桶 SUM 聚合、类别过滤不泄漏、空范围、跨午夜分日 | `verify_history.swift` |

**转写暴露的问题**：`verify_process_usage.swift` 的断言建立在「进程的第一帧就计入统计」之上，而真实实现会丢弃每个新 pid 的首帧（`seenPids`，nettop 把新进程的首帧报成启动以来的累计值）。脚本从未镜像这一点，所以它一直在验证一个与生产代码不同的语义。转写后的测试按真实语义写（每个 pid 需要两帧）。

**为可测性做的一处重构**：`QuotaMonitor.check()` 的跨阈值判定原本内联在循环里并依赖私有的 `prevPercent`，外部无法触达。已提取为静态纯函数 `QuotaMonitor.shouldFire(prev:current:threshold:key:alreadyFired:)`，`check()` 改为调用它，行为不变。

**有意放弃的断言**：

- `normalise(delta:interval:)`（原 `verify_history` 3 条）——验证的是 `Network.makeInterfaceMonitor` 闭包内那一行内联除法。该路径需要真实的 nettop 子进程，无法单测；由「归一化只发生一次」的仓库约定加代码评审保障。
- `volume-conversion`（原 `verify_history` 1 条）——`均值 × 3600` 是显示层算术，没有可调用的独立函数。
- `interval-change-flush`（原 `verify_process_usage` 1 条）——对应已删除的 `ProcessUsageAggregator.flush(using:)`；采样间隔现固定 1 秒，不存在运行期变更路径。
- `first-observation-arms`（原 `verify_quota` 1 条）——「首次观测只武装不触发」由 `check()` 的 `guard let prev = prevPercent else { return }` 实现，而 `prevPercent` 是私有状态，不引入测试专用 API 就无法观察。

### 9.4 语言切换排查（2026-09）

起因是运行日志里的一条 `ERROR [l10n] lproj missing for en; falling back to main bundle`。

**结论：在当前构建上无法复现。** 在真实 app 内把语言切成 English 并重启，日志为 `bundle loaded for en`；另有探针脚本与新增测试确认：21 种语言的 `.lproj` 全部存在于构建产物、全部能打开、且都能读到正确的翻译。

**上一轮的推断是错的。** 当时怀疑 macOS 把 `en` 当作 development region，导致 `path(forResource:ofType:)` 返回 nil；实测 `Bundle.main` 用该 API 能正确定位全部 21 种语言。那条 ERROR 应来自更早的某个构建产物（当时仍在运行、其 bundle 已不可考——排查过程中已把废弃的 `iTrafficPlus.xcodeproj` 与 `build/` 一并清理）。

**仍然做了加固**，因为这个失败模式足够隐蔽，值得从代码里消除：

| 改动 | 理由 |
| --- | --- |
| `reloadBundle()` 改经 `LocalizationManager.lprojBundle(for:in:)` | 原先只有 `path(forResource:ofType:)` 一条查找；它回答的是 bundle 的本地化**状态**而非磁盘实况。落空后直接回退到 main bundle，而 main bundle 解析的是**系统语言**——中文系统上的英文覆盖会静默显示中文，既不报错也不生效 |
| 新增第二条查找：`resourceURL` + `<locale>.lproj` + 存在性检查 | 问的是文件系统的实在问题，磁盘上确实存在的目录不会漏 |
| 错误日志补上 `Bundle.main.bundlePath` | 下次真出现时能一眼看出是哪个 bundle |
| `supportedLocales` 由 `private` 改为 internal | 让测试能断言「列出的每一种语言都真的在产物里」 |
| 新增 `LocalizationTests.swift`（8 条） | 覆盖全部 21 种语言的可定位性与内容，以及 `resolveLocale` 的判定；此类问题不会静默复发 |

### 9.5 手绘日期控件的语言适配（2026-09）

用户报告「设置与历史窗口中的日期控件没有适配多语」。

**根因**：`AccentDateField` 是手绘控件，它把 `dateLabel`（字段里的日期）和 `monthTitle`（月份标题）都正确地指向了 `LocalizationManager.shared.locale`，但**星期表头漏了**——那一行读的是 `Calendar.current.veryShortWeekdaySymbols`，而 `Calendar.current` 的 locale 来自**系统设置**。于是在 `zh_CN` 系统上把语言覆盖成 English，网格上方依然是「日 一 二 三 四 五 六」。

**修复**：不只是换表头的取值来源，而是让整个 `calendar` 跟随 app 语言（`var c = Calendar.current; c.locale = Locale(identifier: l10n.locale)`），因为表头的列顺序由 `calendar.firstWeekday` 旋转决定，而网格里 1 号落在哪一列同样由它计算——两者必须同源，否则表头与日期列会错位。已实测确认给 `Calendar` 赋值 `locale` 会重新派生 `firstWeekday`（`de` → 2 即周一首列，`ar` → 7 即周六首列），所以改一处即可保持一致。

**测试**：`weekdayHeadings(for:)` 提取为 internal 静态函数以便断言；新增 `AccentDateFieldTests.swift`（5 条），其中一条直接断言 `en` 的表头必须是 `["S","M","T","W","T","F","S"]`——在中文系统上这条本身就是回归测试。测试总数 54 → 59。

**后续（同日完成）**：上述遗留的四处硬编码数字格式也已改为 locale 感知，统一走新入口 `Loc.dateFormatter(template:locale:)`——用**模板**而非固定 pattern，字段顺序、分隔符与 12/24 小时制都跟随语言。两处**刻意保持固定格式**：`CSVExporter` 的时间戳（保证导出文件在任何地方都能排序与解析）与 `DataRetentionController.dayKey`（它是内部去重键，不是给人看的标签）。`AlertLogView` 的 Time 列因此从 118pt 加宽到 140pt——英文的 `9/20/2026, 2:30:00 PM` 比原来的固定格式长。测试新增 4 条（共 63 条通过）。

**第二轮：月份标题的调用顺序陷阱。** 用户反馈「还是显示年月，例如 2026年9月」——app 切到任何语言，月份标题都是中文。根因在 `monthTitle` 的语句顺序：`setLocalizedDateFormatFromTemplate("yMMMM")` 写在设置 `.locale` **之前**。该 API 在调用瞬间就按当时的 locale（这台机器是 `zh_CN`）把模板解析成 `y年M月`，之后再改 `.locale` 已经改不动已解析的 pattern。探针实测：

| 顺序 | 结果 |
| --- | --- |
| 先模板后 locale（旧写法） | `2026年9月`，dateFormat = `y年M月` |
| 先 locale 后模板（正确） | `September 2026`，dateFormat = `MMMM y` |

修复即改用 `Loc.dateFormatter(template: "yMMMM")`——该入口先设 locale 再展开模板，顺序本就正确。这也反过来印证了抽这个入口的价值：它会**防止**这类顺序错误，而手写不会。`dateLabel` 用的是 `dateStyle`，在格式化时才解析、与顺序无关，因此未受影响（已把 locale 赋值提前以保持一致）。新增 2 条测试（共 65 条通过），其中一条直接断言 `en` 的月份标题必须是 `September 2026` 且不含「年」。

### 9.6 历史窗口的布局弹性（2026-09）

用户报告「历史窗口不够弹性，在有些本地语言下显示内容会有重叠覆盖」。

**用测量代替猜测**：写了个探针，用 `NSFont` 量出各语言下每个控件的文本需求宽度，再与代码里的硬编码宽度逐一对比。

| 控件 | 硬编码 | 实际需要 | 结论 |
| --- | --- | --- | --- |
| 范围选择器（4 段） | 300pt | en 324 / de 408 / ru 420 / **fr 438** | 7 种语言里 6 种溢出 |
| 接口开关（每个） | 100pt | **en 116** / de 138 / ru 162 | **全部**溢出（连英文都不够） |
| tab 栏（无固定宽度） | 弹性 | 最坏 fr 493（可用 652） | 正常 |
| 表格列头 | 固定列宽 | 最坏 ru `Median (7d)` 74/76 | 勉强，需加保险 |

**根因**：`Picker(.segmented)` 与 `Toggle(.switch)` 都是 **AppKit 桥接控件**——宽度不足时它们不像 SwiftUI 的 `Text` 那样换行或截断，而是**硬绘制到相邻控件上**。硬编码宽度在英文下看着正常，换到德语/俄语/法语就重叠。

**修复**：

- 三处范围选择器（heatmap / app usage / alert log）删掉 `.frame(width: 300)`，改为取固有宽度，由同一行的 `Spacer` 吸收剩余空间
- 接口开关由 `.frame(width: 100)` 改为 `.frame(minWidth: 100)`，每个按自身标签取宽
- 表格列头加 `lineLimit(1)` + `minimumScaleFactor(0.75)`：俄语 `Median (7d)` 已逼近 76pt 列宽，宁可轻微缩字也不要换行（换行会让表头变高、并把排序下划线带偏）
- 窗口根视图由 `.frame(width: 680, height: 560)` 改为 `minWidth` / `minHeight`，内容随窗口缩放——原先窗口本身可拉伸但内容锁死在 680，这也是「不够弹性」的一部分

**未加自动化测试**：这是布局问题，单测无法捕获渲染重叠。测量结论记录在此，将来新增语言可用同样的探针复核。

---

## 10. 参考

- 构建：`brew install xcodegen && xcodegen generate && xcodebuild build -project FlowTrace.xcodeproj -scheme FlowTrace -configuration Debug`
- 特性演进全史：`changelog/0.3.0.md`（按 research milestone 编号，含每项决策理由与验证记录）
- 仓库工作约定与「Active experiments」台账：`AGENTS.md`
- Combine/SwiftUI 陷阱合集：`.trellis/spec/guides/swift-combine-swiftui-pitfalls.md`（老的长文版；与 `.trellis/spec/macos/combine-pitfalls.md` 内容重叠，可任挑一份看）
