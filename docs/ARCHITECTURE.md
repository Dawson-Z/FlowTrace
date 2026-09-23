# FlowTrace 技术架构与目录说明

> 本文档基于当前工作树（macOS 11.0 部署目标、`xcodebuild test` 205 条全部通过）逐文件梳理。
> 所有类型名、方法名、SQL 表名均取自真实代码；引用注释处标注原文出处。

---

## 1. 项目定位与硬约束

FlowTrace 是 [foamzou/ITraffic-monitor-for-mac](https://github.com/foamzou/ITraffic-monitor-for-mac)（iTraffic）的分支。它在保留上游「驱动 `/usr/bin/nettop` 的菜单栏按进程流量监控」这一核心思路的基础上，叠加了一批纯用户态的新特性。

| 约束 | 内容 |
|---|---|
| 发布形态 | 源码 + GitHub Releases 上的 `.dmg` / `.zip`；发布包用自签名身份签名、**不公证**，用户需手动放行首次启动 |
| 许可 | MIT，保留上游 `foam` 的版权行，另加本分支自己的 |
| Bundle ID | `local.FlowTrace` |
| 部署目标 | macOS **11.0** |
| 权限 | 无沙箱扩展、无 `NetworkExtension`、entitlements 为空 `<dict/>` |
| 网络请求 | **零**——上游「只在点击时发一次 GitHub 更新检查」的规则在本分支被强化为「任何情况下都不发请求」 |
| 更新 | **无自动更新**，且不会加 —— 它是上一条的直接推论：一个解释所有进程流量的工具，不该产生无法解释的流量 |
| 依赖 | 零第三方包；SQLite 用系统 `import SQLite3` |
| 应用形态 | 菜单栏应用（`Info.plist` 中 `LSUIElement = true`），popover 式界面 |

底层能力边界：因为仍是用户态 `nettop`，**无法**做按域名/连接的归因，也做不到 NetworkExtension 那种精确的每接口归属。这是刻意保留的架构选择。

---

## 2. 技术栈

| 层 | 选型 | 说明 |
|---|---|---|
| 语言 | Swift 5.0（`SWIFT_VERSION = 5.0`） | |
| UI | SwiftUI 为主 + AppKit 补位 | 无 Charts 框架（需 macOS 13）；所有图表用 `Path` / 矩形手绘 |
| 响应式 | Combine（`@Published` + `sink`） | 见第 7 节「Combine 陷阱」 |
| 持久化 | 系统 SQLite3（WAL + `synchronous=NORMAL`） | 单文件库 + 私有串行队列 |
| 进程调用 | `Foundation.Process` 驱动 `/usr/bin/script` → `/usr/bin/nettop` | |
| 通知 | `UserNotifications`（本地通知） | |
| 登录项 | macOS 13+：`ServiceManagement.SMAppService`；11–12：`~/Library/LaunchAgents` 用户代理 | 两套实现，见 `LaunchAtLoginManager.swift` |
| 构建 | XcodeGen（`project.yml` 为唯一事实来源） | `FlowTrace.xcodeproj` 由 `xcodegen generate` 生成，不入库 |

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
├── FlowTrace.xcodeproj/    由 project.yml 生成，不入库
├── changelog/1.0.0.md      当前版本发布说明（首个编号版本与基线）
├── changelog/0.3.0.md      0.3.0 research-milestone 逐条变更记录（最完整的特性演进史）
├── docs/ARCHITECTURE.md    本文档
├── FlowTrace/              分支自有代码（Feature 模块）
├── FlowTraceTests/         单元测试 target
├── FlowTraceForMac/        上游继承的应用主干源码 + 资源
└── .trellis/               工作流（脚本、agents、tasks、spec）；spec/ 见 4.8
```

### 4.2 `FlowTraceForMac/` — 应用主干

| 文件 | 职责 |
|---|---|
| `AppDelegate.swift` | 入口（`@NSApplicationMain`）。启动顺序、菜单栏 `NSStatusItem` 装配、popover 生命周期与深度休眠、设置窗/历史窗的懒创建、通知代理（前台也弹 banner/sound）、通知被拒时的启动引导弹窗（可永久抑制，XCTest 下跳过）、窗口标题的本地化刷新 |
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
| `AccentColor.swift` | `AccentSource`（`.system` / `.custom`）、`AccentColorManager`（唯一真相源，UserDefaults key：`ft.accent.source`、`ft.accent.hex`，新装默认 custom + `#00CFFF`）、`AccentHexField`、`\.appAccent` 环境值、`View.appAccentScope(_:)`（每个窗口根唯一应用点，同时 `.tint`（12+）/`.accentColor`（11）并发布环境值）、`animationIdentity`（系统模式下属常量，避免无意义淡入） |
| `AccentControls.swift` | 为「AppKit 绘制的表面无法跟随自定义强调色」而手绘的控件：`AccentTextField`（无边框原生编辑 + 自绘聚焦环 + 改写 `selectedTextAttributes` 的文本选区色）、`AccentPicker`（下拉）、`AccentDateField`（本地化月历，设置页与历史窗三个范围过滤器共用）、`accentFieldChrome(isFocused:)` |

系统强调色实时跟随：监听分布式通知 `AppleColorPreferencesChangedNotification`，收到后 `systemAccentRevision &+= 1` 触发重绘。`systemAccentColor` 必须手动解析成具体 sRGB 分量（直接包 `NSColor.controlAccentColor` 在桥接表面会解析错误）。

#### History（历史数据与可视化）

| 文件 | 职责 |
|---|---|
| `RingBuffer.swift` | 泛型定长环形缓冲，预分配数组，append O(1) 不分配 |
| `HistoryStore.swift` | popover sparkline 的数据源。`capacity = 60`；`samples: [HistoryFrame]` + `summary: HistorySummary`（今日峰值 / 24h 均值 / 今日累计）；`bootstrap()` 从磁盘回填最近 60 帧（重启后曲线不空）；`append` 同时发布内存快照并落库 |
| `HistoryView.swift` | popover 底部 60 采样 sparkline（上下两条 `Path`：in 在基线之上、out 在下）+ 峰值/均值 + 打开历史窗按钮 |
| `HistoryWindowView.swift` | 历史窗口根视图，三个 tab：`appUsage`（默认）/ `heatmap` / `alerts`；`.appAccentScope` 在此应用；窗口 `minWidth 680 / minHeight 560` |
| `AppUsageView.swift` | 「App usage」页：范围内每进程累计 ↓/↑/合计，可排序、可导出 CSV |
| `ProcessUsageModel.swift` | 上述页面的 VM：`HeatmapRange` 范围 + `rangeBuckets` 本地分钟桶换算 + 排序 |
| `HistoryHeatmapView.swift` | 热力网格：`dayPerRow`（每天一行 24 列，带行末 Σ）/ `dayPerColumn`（GitHub 风格）；颜色深浅 = (in+out) 相对最忙格子的占比；hover 显示明细 |
| `HistoryHeatmapModel.swift` | 热力图 VM：范围、`selectedCategories`、`cells`、`reload()`、`exportCSV()` |
| `AlertLogView.swift` | 「Alert log」页：`AlertRange`（all/today/7d/30d/custom）+ `AlertSortMode`（time/name/direction/today/median/factor），内存内排序不查库 |
| `ProcessUsageAggregator.swift` | 把每帧进程速率滚入**本地分钟桶**，跨分钟时 flush 成 `bytes = Σ(rate) × interval` 写入 `process_usage`；用 `seenPids` 丢弃每个新 pid 的首帧（否则会把进程启动以来的累计流量灌进桶里） |
| `CSVExporter.swift` | 三种 CSV 形状（process / interface / alert）+ `NSSavePanel`；字节导出为纯数字，单位写在表头 |
| `HistoryPersistence.swift` | SQLite 门面：连接打开 / schema / 保留期清理 / 写入路径。详见第 5 节 |
| `HistoryPersistenceModels.swift` | 持久化层的全部数据模型 struct：`HistoryRow`、`InterfaceHistoryRow`、`HeatmapCell`、`ProcessUsageSummary`、`ProcessUsageFlushRow`、`ProcessAlertRow`、`AlertRecord` |
| `HistoryPersistence+Queries.swift` | 只读查询扩展（各表聚合、`export*` 的读路径）。为了让 extension 能共享同一个 SQLite 句柄与串行队列，`db` / `queue` / `SQLITE_TRANSIENT_BRIDGE` 已由 `private` 放宽为 internal（同模块同 target，未外泄） |

#### Interface（接口维度）

| 文件 | 职责 |
|---|---|
| `InterfaceClassifier.swift` | `InterfaceCategory`（`Wi-Fi` / `Wired` / `Local Direct` / `Other`，rawValue 即显示名且作为落库值）。运行 `/usr/sbin/networksetup -listallhardwareports` 解析 `Hardware Port` ↔ `Device` 映射。**判定优先级**：① 名称启发式先行 —— `awdl0`/`llw0`→Local Direct、`bridge*`→Other（bridge 的端口名只是描述性的：`bridge0` 报作 `Thunderbolt Bridge`，若让端口名先命中就会被误判为 Wired）；② 再查硬件表 —— 端口名含 `wifi`/`wi-fi`→Wi-Fi，含 `usb`/`ethernet`/`thunderbolt`→Wired；③ 表中没有的动态设备 —— 数字 `en*`（`dropFirst(2)` 后全为数字）→Wired，其余→Other。纯函数、可单测 |
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

双 sink 的原因：macOS 11+ 对 **ad-hoc 签名**应用的 `os.log` 施加隐私过滤，日志可在 Console.app「Now」面板看到但**不落盘**，`log show` 读不回来；文件 sink 不受 logd 隐私过滤影响，可 `tail -f`。

分类名（同时是 `Log` 与 `AppLogger` 的属性名）：`appDelegate`、`network`、`nettopRunner`、`persistence`、`settings`、`interface`、`l10n`。

#### Search

| 文件 | 职责 |
|---|---|
| `SearchFilter.swift` | 纯函数 `filter(items:searchText:)`：名称 `lowercased().contains`（恒定大小写不敏感，已无配置项）+ PID 精确匹配；空搜索串原样返回 |
| `ProcessSearchBar.swift` | 单行 `TextField`（绑定 `ListViewModel.searchText`）+ `⌕` 字形 + `×` 清除按钮。**刻意保留平台 `TextField`**，其文本选区跟随系统强调色（AGENTS.md 记录的例外），过滤逻辑不在此处 |

#### Settings

| 文件 | 职责 |
|---|---|
| `SettingsStore.swift` | `ObservableObject` over `UserDefaults.standard`，20 个持久化 key 集中定义（见第 6 节）。含一次性 key 重命名（`showMonthInMenuBar`→`showPeriodInMenuBar`）。`applyAppearance()` 把外观映射到 `NSApp.appearance` 并额外钉住被缓存的 popover 窗口 |
| `SettingsView.swift` | `SettingsTab`（`general / quota / alerts / storage / about`）、`SettingsMetrics`（`width 480 / padding 20 / tabBarHeight 66 / controlWidth 200`）、`SettingsTabSelection`、`SettingsRootView`、手绘 `SettingsTabBar` / `SettingsTabButton`、`SettingsPanes`（按 tab 分发到下面的 pane 文件） |
| `SettingsComponents.swift` | 跨 pane 共用的构件：`SettingsPane`（每个 pane 是独立 SwiftUI root，**必须各自 `.appAccentScope`**）、`SettingsRow` / `SettingsNote` / `SettingsSwitch`、`EditableNumberField`、`AccentTimeField`、`NotificationPermissionWarning`（配额/示警/存储（提醒模式）pane 在「通知能力启用但系统通知不可用」时的橙色内嵌提示：`denied` → 打开系统设置，`notDetermined` → 直接申请） |
| `Settings{General,Quota,Alerts,Storage,About}Pane.swift` | 每个 `SettingsTab` 一个文件。这些 pane 原先是 `SettingsView.swift` 内部的 private 类型，随文件拆分提升为 internal |
| `DataCleaner.swift` | `resetInMemory()`：依次重置 historyStore / usageAggregator / interfaceModel / interfaceMinuteAggregator / processAlertMonitor / quotaMonitor。磁盘侧删除由 Settings 窗口经 `HistoryPersistence.deleteRange` 完成 |
| `DataRetentionController.swift` | 每日保留期检查点：60s Timer 轮询「配置的时间点是否已过且今天是否已执行」，按 `cleanupMode` 自动删除或发提醒；对睡眠/唤醒与时钟变更天然健壮。**任一相关设置（清理方式/保留天数/检查时间）变更都会重置当日标记并立即重查**——否则「检查点跑完之后才改小保留天数」的场景会静默等到第二天（2026-09-23 实测） |
| `LaunchAtLoginManager.swift` | 登录项，两套实现。13+：`SMAppService.mainApp.register/unregister`，状态读 `SMAppService.mainApp.status`。11–12：往 `~/Library/LaunchAgents/local.FlowTrace.login.plist` 写一个 `RunAtLoad` 的 launchd 用户代理，内容为 `/usr/bin/open -g <bundle 路径>`；launchd 在每次登录时扫描该目录，所以**写文件即注册、删文件即注销**，不需要调 `launchctl`。代价是 plist 记的是绝对路径，因此 `currentStatus()` 每次读到 plist 都会按当前 bundle 重写一次，让被移动或被清理的构建目录自愈 |

#### Usage

| 文件 | 职责 |
|---|---|
| `UsageAggregator.swift` | 周期用量积分器：`UsageBytes`（in/out/total）+ `today/week/month` + `bytes(forPeriod:)`。`tick()` 由帧路径调用、内部节流（默认 2s）。菜单栏 `P` 段与 `QuotaMonitor` 共用此单一口径 |
| `LocalNotification.swift` | **本地通知的唯一投递口**。`NotificationDelivery` 类型别名是注入缝（`QuotaMonitor` / `ProcessAlertMonitor` / `DataRetentionController` 都接收一个），`LocalNotification.deliver` 是生产实现：**先查 `getNotificationSettings().authorizationStatus`，再 `add`**。之所以不能只看 `add` 的 error——未授权时 `add` 也返回 `error == nil`（实测），把「用户根本收不到」误判成投递成功。回调统一切到主队列。同文件还有 `NotificationPermissionModel`：可观察的授权状态（`refresh()` / `request()`），供设置页的内嵌警告使用。 |
| `QuotaMonitor.swift` | 配额阈值监视：订阅 `aggregator.$today/$week/$month`，阈值集合 `{80, 100, 自定义}`；跨越检测 `prev < t && current >= t`（已提取为静态纯函数 `shouldFire(...)` 以便单测）；去重 key `"<周期起始日>:<阈值>"` 存 UserDefaults `quotaFiredKeys`，周期滚动后自动重置。含 `ByteFormatter`。<br>**投递语义**：fired key 只在**投递成功后**才写；被拒时按 15 分钟退避重试（内存态，重启即重试），因此用户之后放开权限时能补上通知。<br>**必须在启动时调用 `bootstrap()`**：`SharedStore.quotaMonitor` 是惰性 `static let`，不触碰就永不 `init`、永不订阅，配额会静默失效（`AppDelegate.applicationDidFinishLaunching` 负责调用）。 |
| `ProcessAlertMonitor.swift` | 按进程的异常流量告警：方向独立，需同时满足「今日累计 ≥ 绝对下限（MB）」与「超过该进程 7 日日中位数 × 倍数」；基线为 0 视为「任何流量都异常」。**每进程每方向每自然日最多一条**，去重由 `process_alert` 表的唯一索引 `(day, name_key, direction)` 承担（重启也天然保持）。`decide(...)` 为纯函数。<br>**投递语义**：**先投递、成功后才写去重行**——反过来（原实现）会让「投递被拒」也记上「今日已告警」，用户既没被通知也永不重试。被拒时同样 15 分钟退避重试。 |

### 4.4 `FlowTraceTests/`

22 个测试文件，205 条用例（2026-09）。全部走真实依赖、注入隔离，只是不隔离宿主进程：

| 文件 | 覆盖内容 |
|---|---|
| `ListViewModelSortTests.swift` | `ListViewModel.sort` 的各比较器、并列时的名称次序、空/单元素、幂等性 |
| `ListViewModelMergeTests.swift` | `mergeSameNameProcesses` 的同名合并语义 |
| `ProcessSearchBarTests.swift` / `SearchFilterTests.swift` | 进程过滤纯函数、PID 精确匹配、空串与 `clear` |
| `NetworkParserTests.swift` | `Network.parser` 的首帧丢弃、id 持久化、entity 字段、`interval` 流变 |
| `UsageAggregatorTests.swift` | `tick()` 节流、`today/week/month` 三口径、`bytes(forPeriod:)` 边界 |
| `ProcessUsageAggregatorTests.swift` | 端到端：分钟桶稳定性、同名跨 pid/大小写合并、`bytes = Σ(rate) × interval`、零流量跳过、flush 后不重复累加（回归）、范围查询 `[from, to)`、排序模式 |
| `InterfaceMinuteAggregatorTests.swift` | 与 `ProcessUsageAggregator` 同分钟桶口径、SUM/AVG 一致、跨午夜 |
| `InterfaceClassifierTests.swift` | 含**本机真实 `networksetup -listallhardwareports` 输出**的回归用例 |
| `AlertAndQuotaIntegrationTests.swift` | 端到端：阈值跨越写库、UNIQUE 拦下同日同向第二条、`firedKey` 周期滚动重新武装；**投递被拒时不得写 firedKey、不得写 `process_alert`**（两条回归） |
| `ProcessAlertMonitorTests.swift` | `decide(...)` 双条件（7 日中位数 × 倍数 且 绝对 MB 下限）、冷启动（基线 < 5 不触发）、`seenPids` 首帧丢弃、`reloadBaselines` 7 日窗口 |
| `HistoryPersistenceTests.swift` | SQLite 端到端：`history` / `process_usage` / `process_alert` / `interface_minute` 的写入路径 |
| `HistoryPersistenceQueryTests.swift` | 只读查询：分钟桶聚合、空范围、范围边界、UNIQUE 拒绝、`recent(limit:)` 同步读 |
| `HistoryHeatmapPersistenceTests.swift` | 端到端：`interface_minute` 按本地小时桶 SUM 聚合、类别过滤不泄漏、空范围、跨午夜分日 |
| `LocalizationTests.swift` | 21 种语言的 `.lproj` 是否都在构建产物里、能打开、且取得到已知 key；`Bundle.main` 查找路径（运行时实际走的）覆盖全部语言；中英文不会解析到同一张表；`resolveLocale` 的覆盖 / 跟随系统行为 |
| `AccentColorTests.swift` | hex 解析、sRGB 转换、`readableForeground` 黑白两端、`accentFieldChrome` 焦点状态、`.appAccent` 环境值 |
| `AccentDateFieldTests.swift` | 手绘日期控件的星期表头是否跟随**请求的**语言而非系统语言（`en` 必须得到 `S M T W T F S`）；表头按各语言的周首日轮转、且是本周符号的一个纯重排 |
| `SettingsStoreTests.swift` | key 迁移（`showMonthInMenuBar` → `showPeriodInMenuBar`）、accent key 不归 `SettingsStore` 管、其余默认与边界 |
| `DataCleanerTests.swift` | `resetInMemory()` 顺序、`SharedStore` 重新装配 |
| `CSVExporterTests.swift` / `AlertLogModelTests.swift` / `RingBufferTests.swift` | CSV 转义、`AlertRange.fromMs` 本地日分桶、环形缓冲 O(1) 追加/回绕 |

**测试运行既不隔离、也不是只读 —— 这是已知属性，不是 bug。** `FlowTraceTests` 是跑在 app **内部**的
（`TEST_HOST`），所以 `applicationDidFinishLaunching` 会真实执行：一次测试运行会拉起两个 `nettop`
子进程，并读写用户真实的 `~/Library/Application Support/FlowTrace/history.sqlite3` 与
`~/Library/Logs/FlowTrace.log`。任何经过 `Loc` / `LocalizationManager.shared` 的测试还会实例化
`SettingsStore.shared`，从而读取真实 `UserDefaults` 域，并可能在其中执行一次性 key 迁移。
注入隔离的依赖（`UserDefaults` suite、临时 SQLite 库、`NotificationDelivery` 桩）保证每个测试的
**断言**是干净的，但宿主 app 本身并不在沙箱里。需要真正干净的环境做手工验证时，用
`CFFIXED_USER_HOME=<dir>` 启动构建产物 —— macOS 的 `NSHomeDirectory()` 走 `getpwuid()`，所以
只设 `HOME` **不行**，而 `CFFIXED_USER_HOME` 会。它只重定向文件路径；`UserDefaults` 仍解析到真实域。

### 4.5 本地化资源（`FlowTraceForMac/*.lproj/`）

21 种语言各含一份 `Localizable.strings`：
`en`、`zh-Hans`、`zh-Hant`、`es`、`pt-BR`、`fr`、`de`、`it`、`ru`、`ja`、`ko`、`vi`、`hi`、`bn`、`ur`、`pa`、`mr`、`ta`、`jv`、`ar`、`fa`。
其中 `zh-Hans` 与 `zh-Hant` 额外含 `InfoPlist.strings`。

`project.yml` 把全部 `.lproj` 从 `sources` 里排除，再逐个以 `buildPhase: resources` 显式声明（否则生成器不会把它们当资源打包）。

### 4.6 `.trellis/` — 工作流与项目规范

| 路径 | 主题 |
| --- | --- |
| `spec/index.md` | 顶层索引；必读 |
| `spec/macos/index.md` | 项目描述 + 5 个子规范索引 + Hard Rules |
| `spec/macos/project-layout.md` | `FlowTraceForMac/` 与 `FlowTrace/Feature/<Name>/` 的边界、target 接线、import 规则、与 AGENTS.md 的仲裁 |
| `spec/macos/swiftui-conventions.md` | `@StateObject` vs `@ObservedObject`、accent scope、AppKit bridge、`lineLimit` + `minimumScaleFactor` |
| `spec/macos/combine-pitfalls.md` | `@Published` willSet race、deferred UI update、locale 桥接 staleness |
| `spec/macos/localization.md` | `Loc.l` 与 `Loc.dateFormatter`、`setLocalizedDateFormatFromTemplate` 顺序陷阱、机器用时间戳例外 |
| `spec/macos/persistence.md` | SQLite schema、串行队列、两套时间基准（`ts` epoch-ms vs `minute_bucket` 本地分钟序数）、三条清理路径 |
| `spec/guides/index.md` | 思考指南索引 |
| `spec/guides/code-reuse-thinking-guide.md` | 重复模式识别 |
| `spec/guides/cross-layer-thinking-guide.md` | 跨层数据流陷阱 |
| `spec/guides/swift-combine-swiftui-pitfalls.md` | Combine 坑点长文（与 `macos/combine-pitfalls.md` 内容重叠） |

Trellis agents（`agents/implement.md`、`agents/check.md`）已重写，明确引导到 `macos/` 与 AGENTS.md。**AGENTS.md 仍是最终仲裁者**——当 spec 与 AGENTS.md 冲突时以 AGENTS.md 为准（agents 也按这条规则运行）。

---

## 5. 持久化：`HistoryPersistence`

### 5.1 位置与打开参数

- 路径：`~/Library/Application Support/FlowTrace/history.sqlite3`
- **一次性目录处理**：首次启动时若 `FlowTrace/` 子目录不存在则创建。
- 打开标志：`SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX`
- PRAGMA：`journal_mode = WAL`、`synchronous = NORMAL`
- **WAL 边车文件（备份注意）**：WAL 模式下磁盘上是**三个文件**——`history.sqlite3`（上次检查点为止）、`history.sqlite3-wal`（已提交但未合并的事务）、`history.sqlite3-shm`（WAL 的共享内存索引）。应用**从不做显式检查点**：唯一的 `sqlite3_close` 在 `HistoryPersistence.deinit` 里，而持有者 `SharedStore.historyPersistence` 是 `static` 存储（活到进程结束才回收），该 `deinit` 不会执行；`applicationWillTerminate` 也不关库。因此**退出后 `-wal` 通常仍在**。
  **这不丢数据**——下次打开时 SQLite 自动重放 WAL，读取方看到的始终是「主库 + WAL」的并集；但**备份 / 搬移 / 交接必须三个文件一起拷**，只拷 `history.sqlite3` 会丢掉 `-wal` 里尚未合并的最近数据。**也不要靠删掉边车文件来"清理"**，那等于丢弃它们承载的事务。WAL 不会无限增长：SQLite 默认在 1000 页（约 4 MB）自动检查点。

### 5.2 表结构

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

### 5.3 线程模型

- 单个私有串行队列 `DispatchQueue(label: "history-persistence", qos: .utility)` 独占全部 `sqlite3_*` 调用；**主线程从不触碰 SQLite**。
- 写方法（`append` / `appendInterface` / `appendInterfaceMinute` / `appendProcessUsage` / `appendProcessAlert`）立即返回，实际写在队列上执行。
- 读方法默认 `queue.async` 查询后回主队列回调；唯一同步读是 `recent(limit:)`——有界、走索引，且只在启动期调用。

### 5.4 保留与清理（三条不同路径，范围各不相同）

| 触发 | 方法 | 覆盖表 |
|---|---|---|
| 启动时一次 | `prune()`（按 `retentionSeconds`） | `history`、`interface_history`、`process_usage`、`interface_minute`（**不含** `process_alert`） |
| 每日检查点（自动模式） | `pruneExpired(cutoffMs:cutoffBucket:)` / `expiredRowCount(...)` | `ts` 组：`history`、`interface_history`、`process_alert`；桶组：`process_usage`、`interface_minute` |
| 用户手动 | `clearAllTables(completion:)`（5 表），`deleteRange(fromMs:toMs:fromBucket:toBucket:)` / `countRange(...)`（4 表） | 见左 |

默认保留期 7 天，实际值由 `SettingsStore.historyRetentionDays`（默认 30）在启动时传入。

### 5.5 查询 API 一览

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

## 6. 配置项：`SettingsStore`

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
- `notificationLaunchReminderSuppressed` —— `AppDelegate`（通知被拒时启动引导弹窗的「不再提醒」）
- 非持久化：`refreshInterval` 是 `let = 1`（固定 1s，UI 已取消该选项）

写入路径统一用 `$prop.dropFirst().sink { ... }`，而**不用 `didSet`**——`didSet` 会在 init 的播种赋值阶段触发，把磁盘上已有的值再写回一遍并产生虚假的「用户改过」日志。

---

## 7. 工程约定与已知陷阱

### 7.1 构建与资源

- `project.yml` 是唯一事实来源，改完跑 `xcodegen generate`；**只提交 YAML** —— 生成出来的 `FlowTrace.xcodeproj` 有意不入库，`.gitignore` 已排除。
- 两个 target：应用 `FlowTrace`（`MACOSX_DEPLOYMENT_TARGET = 11.0`）与单测 `FlowTraceTests`（`bundle.unit-test`，`TEST_HOST` 指向应用）。
- `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`；**刻意不设** `GLOBAL_ACCENT_COLOR_NAME`——一旦指向内置的 `AccentColor.colorset`（硬编码 `#00CFFF`），它在启动时就会成为 AppKit 控件强调色并覆盖根部的 `.tint(nil)`，导致「跟随系统」分支永远无法回落到 macOS 强调色。
- Release 开 `ENABLE_HARDENED_RUNTIME`（Apple 公证的硬性要求之一）；`project.yml` 里签名保持 ad-hoc，因此全新 clone 无需证书即可构建 —— 发布构建改为在命令行上覆盖签名身份，完整流程见 AGENTS.md 的「发布」一节。

### 7.2 代码约定

- **速率字段自带单位**（`inBytesPerSec` / `totalInBytesPerSec`），归一化只在 `Network.parser` 发生一次。
- **`.help(_:)` 需 `#available` 守卫**（macOS 11+），不要为它抬高部署目标。
- **SF Symbols 用 `.font` 缩放，禁止 `.resizable()`**；菜单栏尺寸下小号图标优先用 Unicode 字形（如 `⌕`、`⚙`、`↗`）。
- **每个独立托管的 SwiftUI 根都要应用 `.appAccentScope`**：popover、`SettingsPane`（每个 pane 各自一个 `NSHostingController`，没有共享父级）、历史窗口。
- **`.tint` 只覆盖 SwiftUI 绘制的内容**；AppKit 绘制的语义色（`controlAccentColor`、键盘焦点环、文本选区、下拉菜单）无法通过公开 API 按应用覆盖，自定义强调色要生效必须用 `AccentControls.swift` 里的手绘控件。
- 手绘控件在字段**销毁前**必须提交编辑：三个钩子是 `controlTextDidEndEditing`、`NSControl.textDidEndEditingNotification`（`object: field`）、`NSWindow.willCloseNotification`；切 tab 时由 `SettingsTabBar.commitPendingEdit()` 先 resign。**绝不能在 `dismantleNSView` 里提交**——那里在 `NSHostingView.deinit` 内部，通过 `@Binding` 回写会触发 SwiftUI 排他性检查并 `EXC_CRASH / SIGABRT`。
- **永远不要给桥接 AppKit 控件固定宽度**。`Picker(.segmented)` 和 `Toggle(.switch)` 是 AppKit 视图：不按 SwiftUI `Text` 的方式换行或截断，而是绘制到旁边的任何东西上。固定宽度列里的 SwiftUI `Text` 没问题（会换行），但若换行会让行高错，请用 `lineLimit(1)` + `minimumScaleFactor`。

### 7.3 Combine / SwiftUI 陷阱（`@Published` 发射早于写入）

`@Published` 的 `willSet` 语义意味着 sink 在属性被写入**之前**运行。已在代码中被踩到并记录：

- 排序模式：sink 内必须使用**事件携带的** mode，否则「晚一拍生效」。
- 刷新间隔：同上，且在重启子进程前先更新 `interval`，保证归一化用当前值。
- 设置窗尺寸：sink 内同步 `setFrame` 会在 SwiftUI 更新中重入 AppKit（表现为窗口变了、pane 没变），须 `DispatchQueue.main.async` 延后一个 runloop。
- 外观切换：需同样延后一拍，否则被 AppKit 合并掉（表现为「UI 落后一次选择」）。

### 7.4 数据正确性要点

- 首帧必须丢弃：`NettopRunner` 与 `InterfaceMonitor` 都各自丢弃 spawn 后的第一帧（累计值而非增量）。
- 每个新 pid 的首帧必须丢弃：`ProcessUsageAggregator.seenPids`。
- `InterfaceMonitor` 必须跳过 interface 列为空的行，否则每项统计翻倍。
- 分钟桶累加器**无论是否写盘都要清空**——不清会让后续每次 flush 变成「自始至今的总和」（曾导致「结果远大于真实值」的 bug）。
- 按名聚合的行**绝不能调 `getAppInfo(pid: 0, ...)`**，否则所有行共用 pid 0 的缓存槽，显示成同一个名称。

---

## 8. 参考

- 构建：`brew install xcodegen && xcodegen generate && xcodebuild build -project FlowTrace.xcodeproj -scheme FlowTrace -configuration Debug`
- 仓库工作约定与「Active experiments」台账：[AGENTS.md](../AGENTS.md)
- 当前版本发布说明：[changelog/1.0.0.md](../changelog/1.0.0.md)（首个编号版本与基线）
- 特性演进全史：[changelog/0.3.0.md](../changelog/0.3.0.md)（按 research milestone 编号，含每项决策理由与验证记录）
- 英文版架构文档：[docs/ARCHITECTURE.en.md](ARCHITECTURE.en.md)
- Combine/SwiftUI 陷阱合集：[.trellis/spec/guides/swift-combine-swiftui-pitfalls.md](../.trellis/spec/guides/swift-combine-swiftui-pitfalls.md)（老的长文版；与 [.trellis/spec/macos/combine-pitfalls.md](../.trellis/spec/macos/combine-pitfalls.md) 内容重叠）
