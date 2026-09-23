# FlowTrace 全方位测试结果（2026-09-22）

> 本文为 [docs/TESTING.md](TESTING.md) 计划执行的结果记录。
> 执行环境：macOS、Xcode 16.4、xcodebuild + XCTest。

## 1. 总览

| 项 | 数值 |
|---|---|
| 总用例数 | **167**（第一轮 131 + 复审补充轮 36）|
| 通过 | **162** |
| 失败 | **5**（均为 InterfaceClassifier 故意保留的「bug 暴露」测试，非真实失败）|
| 总用时 | 6.9s（Debug）+ 1.46s（基线）|
| Release 构建 | **BUILD SUCCEEDED** |
| 二进制架构 | `x86_64 arm64`（Universal）✓ |
| Hardened runtime | `0x10002(adhoc,runtime)` ✓ |
| 签名身份 | ad-hoc（与 AGENTS.md §Releases 设计一致）|

基线对比：原本 65 例 → 现在 167 例，新增 102 例，全部通过（不含 5 个 bug 暴露测试）。

**复审补充说明**：第一轮完成后对源码树做了一次覆盖审计，发现 `RingBuffer`、`Utils.formatBytes`、`CSVExporter`、`AlertLogModel`、`ProcessUsageModel.rangeBuckets`、`InterfaceMinuteAggregator`、`HistoryStore`、`InterfaceModel` 等 8 个模块可自主测试但未覆盖，已补入 K 组（36 项）并全部跑通。

---

## 2. 各组用例与结果

### A. 构建与产物（6 项）— **全过**

| ID | 用例 | 结果 |
|---|---|---|
| A1 | XcodeGen 干净生成 | ✓ |
| A2 | Debug 构建 | ✓ |
| A3 | Debug 单元测试构建 | ✓ |
| A4 | Release 构建 | ✓ BUILD SUCCEEDED |
| A5 | Universal 二进制 | ✓ `x86_64 arm64` |
| A6 | 资源完整性（21 个 .lproj） | ✓ |

### B. 进程列表 & 搜索（5 项新增 + 原有）— **全过**

`SearchFilterTests` 新增 5 项：空搜索、空白、大小写、PID 匹配、双重匹配。
`ListViewModelSortTests`（10 例）、`ListViewModelMergeTests`（6 例）原有已覆盖幂等、tie-breaker、单元素。

| 文件 | 用例数 | 结果 |
|---|---|---|
| SearchFilterTests | 5 | ✓ 5/5 |
| ListViewModelSortTests | 10 | ✓ 10/10 |
| ListViewModelMergeTests | 6 | ✓ 6/6 |

### C. 数据归一化 & 累加器（12 项）— **全过**

`NetworkParserTests` 新增 5 项，覆盖 parser 是唯一除法点（issue #28 回归点）。
`UsageAggregatorTests` 新增 2 项（bytes 路由、UsageBytes.total）。
`ProcessUsageAggregatorTests` 原有 5 项全过。

### E. 进程异常告警（9 项新增）— **全过**

`ProcessAlertMonitorTests` 新增 9 项：decide 双条件、零基线 + 超 floor、零基线 + 低 floor、方向独立、median 奇偶、dayOrdinal、direction helper。
E3 原假设有误，已修正：源码的 floor 是硬条件，零基线不会绕过。

### F. 接口分类（11 项）— **5 项失败：暴露源码真实 bug**

详见第 3 节「Bug 报告」。
其余 6 项（AWDL/llw0、bridge、空名、大小写等）通过。

### G. 持久化层（12 项）— **全过**

`HistoryPersistenceTests` 新增 12 项：建库、Schema、append/recent、summary、范围查询、interface_minute 聚合、prune init 不动 alert、pruneExpired 全表删、deleteRange 全表删、不动 alert、UNIQUE 去重、主线程并发。

### H. 本地化 & 强调色（12 + 5 + 14 原有 = 31 项）— **全过**

`AccentColorTests` 新增 12 项：normalizedHex 接受/拒绝、setCustomHex、默认值、持久化、烂值回退、readableForeground（含黑白两端亮度对比）、resetToDefault、color round-trip。
`AccentDateFieldTests` 原有 5 项（手绘日期控件星期表头跟随请求语言）。
`LocalizationTests` 原有 14 项覆盖 21 语言、template/locale、month title、zh-Hans vs zh-Hant 等。

### I. SettingsStore & DataCleaner（11 项）— **全过**

`SettingsStoreTests` 新增 6 项：默认值、迁移、键写入、appearance 映射、quotaLimitGB 钳制、保留天数。
`DataCleanerTests` 新增 5 项：historyStore clearMemory、usageAggregator reset、quotaFiredKeys、processAlertMonitor reset、resetInMemory 幂等。

### K. 复审补充轮（36 项）— **全过**

第一轮结束后复审源码树补齐的 8 个模块：

| 文件 | 用例数 | 覆盖内容 |
|---|---|---|
| RingBufferTests | 6 | FIFO、环形回绕、removeAll、容量 1、空 snapshot |
| UtilsFormatBytesTests | 6 | formatBytes/formatBytesCompact/ByteFormatter 阶梯与边界（0.05K 阈值、GB 档回归）|
| CSVExporterTests | 4 | 三种 CSV 形状、逗号/引号转义、零基线 Factor 留空 |
| AlertLogModelTests | 4 | 六种排序模式、direction 分组、fromMs 范围序、custom 截断零点 |
| ProcessUsageModelRangeTests | 3 | rangeBuckets 嵌套关系（1440 分钟/日）、custom 跨度、heatmap 本地日序数往返 |
| InterfaceMinuteAggregatorTests | 4 | 跨分钟 flush、不重复累加、两聚合器桶对齐、reset 丢弃在途分钟 |
| HistoryStoreTests | 4 | append 封顶、clearMemory 不动磁盘、bootstrap 回填、无持久化 no-op |
| InterfaceModelTests | 4 | 相同快照不重发布、今日累计、缺席类别不造零行、reset |
| AccentColorTests（补强）| +1 | readableForeground 黑白两端亮度对比 |

补充过程中修正了 2 处测试自身的初版错误（`fromMs` custom 的 startOfDay 截断语义、`date(forDay:)` 的本地日序数语义），非产品问题。

---

## 3. Bug 报告（InterfaceClassifier）

测试发现 **2 个 InterfaceClassifier 真实 bug**。两种都让代码行为与 ARCHITECTURE.md §4.3 / 注释里写的契约不符：

### Bug #1 — Wi-Fi 端口永远不识别为 `.wifi`

**位置**：[`InterfaceClassifier.swift` line 109-110](file:///Users/dawson/YYProject/private/FlowTrace/FlowTrace/Feature/Interface/InterfaceClassifier.swift#L109-L110)

```swift
if let port = portByDevice[name] {
    let p = port.lowercased()
    if p == "wifi" { return .wifi }    // ← 永不命中
```

**问题**：`/usr/sbin/networksetup -listallhardwareports` 输出的 `Hardware Port` 是 `"Wi-Fi"`（带连字符、首字母大写）。`"Wi-Fi".lowercased() = "wi-fi"`，**永不可能等于 `"wifi"`**。注释里说 Wi-Fi 优先于 en* 启发式，实际 Wi-Fi 走不到 wifi 分支，只能靠 `en*` 的兜底逻辑（而兜底又是 bug #2）。

**影响**：实际机器上 en1 是 Wi-Fi，但 classify(`en1`) 不会走 wifi 分支。

**修复方向**：
```swift
if p == "wifi" || p == "wi-fi" { return .wifi }
// 或者用 Locale(identifier: "en_US") 显式 lowercase
// 或者用 contains("wifi")
```

### Bug #2 — numeric `en*` 永远识别为 .other

**位置**：[`InterfaceClassifier.swift` line 122](file:///Users/dawson/YYProject/private/FlowTrace/FlowTrace/Feature/Interface/InterfaceClassifier.swift#L122)

```swift
if lower.hasPrefix("en") && lower.dropFirst().allSatisfy({ $0.isNumber }) {
    return .wired
}
```

**问题**：`dropFirst()` 只去掉第一个字符 `'e'`，剩下的 `'n1'` 含字母 `'n'`，`Character.isNumber` 对 `'n'` 是 false → `allSatisfy` 返回 false → **永不命中**。

注释里的设计意图是「en* 后跟数字就是 wired」，正确实现应是 `dropFirst(2)`。

**影响**：en2/en3/en4/en13 等动态 NIC 全部归到 .other，UI 上的类别标签是错的。

**修复方向**：
```swift
if lower.hasPrefix("en") && lower.dropFirst(2).allSatisfy({ $0.isNumber }) {
    return .wired
}
// 也要保护 dropFirst(2) 后为空（如 name="en"）：en 单独也算 wired
```

### Bug 暴露测试

`InterfaceClassifierTests` 中以下 5 个测试目前失败，是因为它们故意把期望写成「源码当前实际行为」，用 `XCTAssertNotEqual(.other)` 表达「实际不该落 .other」：

| 测试 | 当前实际 | 期望 |
|---|---|---|
| `testWifiPort` | .other | .wifi |
| `testUnknownNumericEn` (en13) | .other | .wired |
| `testUnknownNumericEn` (en2) | .other | .wired |
| `testUnknownNumericEn` (en0) | .other | .wired |
| `testEn1NotInTable` | .other | .wired |

修复源码后把 `XCTAssertNotEqual(.other)` 改回 `XCTAssertEqual(.wifi / .wired)` 即可。

---

## 4. 已知遗留 / 跳过

| 项 | 原因 |
|---|---|
| `NettopRunner` / `InterfaceMonitor` 真子进程 | 真实环境依赖 + 难稳定复现 |
| `launchd plist` 真实注册 | 写用户 LaunchAgents 不可逆 |
| `DataRetentionController.tick` 时间门槛 | Timer + SharedStore 单例强耦合，无法注入；删除路径已由 G8 覆盖 |
| `AppLogger` / `LogFileSink` | 写用户真实日志文件 |
| `Utils.getAppInfo` / `getAggregatedAppInfo` | 依赖 NSWorkspace 真实运行环境 |
| 菜单栏 UI 渲染 | 视觉确认，需手工 |
| 通知权限 UX | 由 [TESTING.md §9.6](TESTING.md) 手工验证 |
| Release 签名身份 | 用户身份由发布者持有，本机 ad-hoc 是预期 |
| `UsageAggregator.tick` 节流 | 依赖 SharedStore.historyPersistence，未单测 |
| `LocalizationManager` 全 21 语言字典加载 | 已有 LocalizationTests 14 项覆盖 |

---

## 5. 回归建议

### 必须修（影响真实行为）

1. **InterfaceClassifier Bug #1**（Wi-Fi 永远不 wifi）— 用户会看到自家 Wi-Fi 标成 other。
2. **InterfaceClassifier Bug #2**（numeric en* 永远不 wired）— 几乎所有 Mac 上都有动态 en* 设备，UI 显示会是错的。

### 可接受

3. `UsageAggregator.tick` 节流未单测 — 单测需要持久化替身；现有 `QuotaMonitorTests` 间接覆盖了节流路径（`observeUsage`）。
4. `process_alert` 跨日重新武装 — 依赖 SQL baseline 表，目前 E7 是 mock 替身。真实路径由 ProcessAlertMonitor.bootstrap 在启动期触发。

### 测试清理

5. `testWifiPort` / `testUnknownNumericEn` / `testEn1NotInTable` — 修复源码后改回 `XCTAssertEqual` 期望值。

---

## 6. 修复源码示例

`InterfaceClassifier.swift` 修复建议（仅供参考）：

```swift
// line 109
let p = port.lowercased()
if p == "wifi" || p == "wi-fi" { return .wifi }   // 修 #1

// line 122
if lower.hasPrefix("en") && lower.dropFirst(2).allSatisfy({ $0.isNumber }) {
    return .wired                                   // 修 #2
}
```

修复后跑：

```bash
xcodegen generate
xcodebuild test -project FlowTrace.xcodeproj \
  -scheme FlowTrace -configuration Debug \
  -derivedDataPath build COMPILER_INDEX_STORE_ENABLE=NO
```

应得 **167/167 通过**。

---

## 7. 自动化命令（CI 可复用）

```bash
# 1. 环境
xcodegen generate

# 2. 跑全部自主测试
xcodebuild test -project FlowTrace.xcodeproj \
  -scheme FlowTrace -configuration Debug \
  -derivedDataPath build COMPILER_INDEX_STORE_ENABLE=NO

# 3. Release 构建体检（发布前）
xcodebuild build -project FlowTrace.xcodeproj \
  -scheme FlowTrace -configuration Release \
  -derivedDataPath build COMPILER_INDEX_STORE_ENABLE=NO

APP=build/Build/Products/Release/FlowTrace.app
lipo -info "$APP/Contents/MacOS/FlowTrace"
codesign -dv "$APP" 2>&1 | grep -E "(Format|Authority|Signature|flags)"
```

---

## 8. 需您手工验证的部分（来自 TESTING.md §9）

以下不计入自主测试，需独立执行：

- 9.1 菜单栏 UI 渲染（5 项）
- 9.2 端到端冒烟（4 项）
- 9.3 LaunchAtLogin 真实注册（3 项）
- 9.4 强调色 AppKit 表面行为（4 项）
- 9.5 Release 产物体检（5 项，已用 ad-hoc 完成 4 项，唯一签名身份项需发布者持有者）
- 9.6 通知与权限（3 项）

详见 [docs/TESTING.md](TESTING.md)。