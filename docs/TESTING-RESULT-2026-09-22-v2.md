# FlowTrace 全方位功能测试结果 v2（2026-09-22）

> 执行 [docs/TESTING.md](TESTING.md)（v2 分层计划）的结果记录。
> 环境：macOS / Xcode 16.4。
> **本次测试未修改任何产品源码**（§7 源码开缝已裁决为不批准）；改动仅限 `FlowTraceTests/` 与 `docs/`。
> 注：工作树中 `FlowTrace/`、`FlowTraceForMac/`、`project.yml` 的既有改动 mtime 为 09-21 17:34 / 09-22 14:13 / 15:50，**均早于本次会话开始（约 17:00）**，与本次测试无关。

---

## 1. 总览

| 层 | 内容 | 用例数 | 结果 |
|---|---|---|---|
| L1 | 已有单测 | 167 | 162 通过 / 5 失败（均为 Bug #1/#2 暴露项） |
| L2 | 集成补充 | 27 | **27 / 27 通过** |
| L3 | 真实子进程 | 6 | **6 / 6 通过** |
| **一次 `xcodebuild test` 合计** |  | **200** | **195 通过 / 5 失败** |
| L4 | 应用级端到端 | 9 场景 | **9 / 9 PASS** |
| L4 用时 | 约 110s（含 70s 长跑） |  |  |
| 测试套件用时 | 21.2s |  |  |

**5 项失败全部是 `InterfaceClassifier` 的已知缺陷暴露测试**，不是回归：

```
InterfaceClassifierTests.testWifiPort()            ← Bug #1
InterfaceClassifierTests.testUnknownNumericEn()    ×3  ← Bug #2
InterfaceClassifierTests.testEn1NotInTable()       ← Bug #2
```

> **本节是修复前那次运行的快照。** 三个缺陷随后已修复并重跑：**203 / 203 全绿**，
> 该 5 项已转为正向断言。完整修复记录见 **§11**。

---

## 2. L2 集成补充（27 项，全通过）

| 文件 | 用例数 | 覆盖 |
|---|---|---|
| `HistoryPersistenceQueryTests.swift` | 11 | 上轮**从未被调用过**的读 API：`usageBytes` / `historyUsageBytes` / `todayProcessTotals` / `dailyProcessTotals` / `countRange` / `expiredRowCount` / `exportProcessUsage` / `exportInterfaceMinute` / `date(fromLocalMinuteBucket:)` |
| `AlertAndQuotaIntegrationTests.swift` | 5 | 告警与配额的 **fire 路径**真实落库：告警写 `process_alert`、UNIQUE 去重、方向独立、配额写 `quotaFiredKeys`、周期滚动重新武装 |
| `SharedStoreWiringTests.swift` | 3 | `attachHistoryPersistence` 换装后落库、`resetInMemory` 只清内存、nil 持久化降级不崩 |
| `LocalizationResourceTests.swift` | 6 | 21 张表全部非空且互异、表规模抽查、缺 key 回退到 key 本身、InfoPlist 表只随中文包发布 |
| `SettingsStoreTests.swift` | +1 | 19 个持久化 key 全量往返 |
| `AccentColorTests.swift` | +1 | 3 个早期遗留 key 在 init 时被清理 |

关键断言示例：

- **`countRange` 与 `deleteRange` 必须对同一区间给出同一行数**（4 表合计）→ 通过，均为 5 行。
- **`expiredRowCount` 预告的行数必须等于 `pruneExpired` 实际删除的行数** → 通过，均为 3 行。
- **配额 97.66% 只应触发 80 档、不得触发 100 档** → 通过（fired key 仅 `…:80`）。

---

## 3. L3 真实子进程（6 项，全通过）

`-L <samples>` 让 nettop 输出指定采样后**自行退出**，全程无需 kill 子进程。

### 3.1 真实帧格式（L3-2）

per-process 模式 CSV 表头为 `,bytes_in,bytes_out,`，数据行形如 `name.pid,in,out,`。

**生产解析器 `Network.parser` 吃下了全部真实行：72 / 72 条解析成功**，`pid > 0` 且名称非空。
样本：`launchd.1,59400,59400,`、`remoted.335,9193,10905,`

### 3.2 socket 模式与「2× 翻倍」的真实来源（L3-3）

| 观测 | 值 |
|---|---|
| 带 interface 的行 | 199 条 |
| **interface 为空的进程汇总行** | **40 条** |
| 其中能在带 interface 侧找到**完全相同字节对**的 | **23 条** |
| 实际出现的接口 | `awdl0`, `bridge100`, `en1`, `en11`, `en13`, `en7`, `llw0` |

直接配对的实例（原始输出）：

```
remoted.335,,8869,10453,                                    ← interface 空（进程汇总行）
tcp6 fe80::9879:fff:fe98:c0f9%en13.51527<->*.*,en13,8869,10453,   ← 同一份字节数
```

**这就是源码注释所述「不跳过空 interface 行会让每项统计翻倍」的现场证据**——两行字节数完全相同。`InterfaceMonitor.parse` 跳过它们是正确的。

### 3.3 真实硬件端口表与归类矩阵（L3-4）

本机真实表（10 个设备）与 `classify()` 实际结果：

| Device | Hardware Port | 期望 | 实际 | |
|---|---|---|---|---|
| en0 | Ethernet | .wired | .wired | ✅ |
| en5 / en6 / en10 | Ethernet Adapter (…) | .wired | .wired | ✅ |
| **en1** | **Wi-Fi** | **.wifi** | **.other** | ❌ **Bug #1** |
| en2 / en3 / en4 | Thunderbolt N | .wired | .wired | ✅ |
| en11 | iPhone USB | .wired | .wired | ✅ |
| **bridge0** | **Thunderbolt Bridge** | **.other** | **.wired** | ⚠️ **Bug #3** |

测试输出：`与期望不符的设备：bridge0, en1`

### 3.4 首帧是累计值（L3-5）——决定性证据

同一进程连续三帧的原始数据：

```
FlClashCore.962,211629661,62292333,   ← 帧1
FlClashCore.962,0,25,                  ← 帧2
FlClashCore.962,88,0,                  ← 帧3
```

聚合到全进程后：

| | 值 |
|---|---|
| 帧 1 总和 | **459,837,531** |
| 帧 2 总和 | **140** |
| 比值 | **3,284,553.8 倍** |

首帧与后续帧相差 **6 个数量级**。这实证了 `NettopRunner.droppedFirstFrame`（整帧丢弃）与 `ProcessUsageAggregator.seenPids`（每个新 pid 首帧丢弃）的必要性——若不丢弃，进程启动以来的累计流量会被灌进分钟桶。

> 这一项原本要靠「源码开缝」才能单测；您裁决不动源码后，改由真实数据验证，**可信度高于 mock**。

### 3.5 采样间隔（L3-6）

`-L 3 -s 1` 实际耗时 **2.03s**，符合 3 个采样 ≈ 2~3s 的预期，`-s` 生效。

---

## 4. L4 应用级端到端（9 场景，全 PASS）

以 `CFFIXED_USER_HOME=/tmp/flowtrace-e2e-*` 启动**真实构建的 .app 二进制**。

| 场景 | 结果 | 证据 |
|---|---|---|
| L4-1 冷启动存活 | **PASS** | 8s 后进程存活 |
| L4-2 隔离生效 | **PASS** | `history.sqlite3` + WAL + SHM 建在临时 home 下；**真实数据目录 mtime `1788399551` 前后完全一致** |
| L4-3 `history` 落库 + 首帧复核 | **PASS** | 7 行；`min=1741 / max=11303`；首行 `3687\|11826`；**首行 ÷ 后续最大 = 0.326**（同阶 ⇒ 首帧确已丢弃） |
| L4-4 `interface_history` + 量级交叉核对 | **PASS** | 9 行；`Local Direct 2 行 (564/90)`、`Wired 7 行 (37228/58672)`；**接口侧 ÷ 进程侧 = 0.945 ≈ 1**（若空 interface 行未跳过应 ≈2 ⇒ 确已跳过） |
| L4-5 分钟桶 flush（70s 长跑） | **PASS** | `process_usage` 14 行 / 1 个分钟桶 / `sum_in=88064`；`interface_minute` 3 行；Top：`Trae CN Helper 26969/83337`、`Electron 38990/9177`、`WeChat 5218/8959` |
| L4-6 日志无 ERROR | **PASS** | 10 行日志 / **0 条 ERROR** |
| L4-7 优雅退出 | **PASS** | SIGTERM 后进程退出；**无残留 `nettop` 子进程**（进程树清理有效） |
| L4-8 重启 bootstrap 回填 | **PASS** | `bootstrap: seeded 60 frames from on-disk history` ⇒ 重启后 sparkline 不空 |
| L4-9 窗口路径冒烟 | **PASS** | `FLOWTRACE_OPEN=history` / `=settings` 各存活 6s；日志含 `history window opened`、`settings window opened` |

### 4.1 全链路已被证实的部分

L4-3/L4-4/L4-5 合起来证明**完整数据链路在真实运行下是通的**：

```
真 nettop（per-process） → Network.parser → historyStore → SQLite `history`
真 nettop（socket）      → InterfaceMonitor.parse → 分类器 → SQLite `interface_history`
分钟跨边界               → ProcessUsageAggregator.flush → SQLite `process_usage`
重启                     → HistoryStore.bootstrap → 回填 60 帧
```

### 4.2 L4-4 顺带证实 Bug #1 的真实影响

`interface_history` 的 category 分布里 **完全没有 `Wi-Fi` 桶**（只有 `Wired` 与 `Local Direct`）。

本机 Wi-Fi 是 `en1`，而 `classify("en1")` 返回 `.other`（Bug #1）。所以**用户的 Wi-Fi 流量不会进入 Wi-Fi 桶**——这是 popover 接口概览上可见的功能缺陷，不是理论问题。

### 4.3 观察项（非缺陷）

- **退出后 WAL 未合并**：SIGTERM 后 `-wal` 仍为 2,002,352 字节。`applicationWillTerminate` 只记日志、未 `sqlite3_close`；而唯一的 `sqlite3_close` 在 `HistoryPersistence.deinit`，其持有者 `SharedStore.historyPersistence` 是 `static` 存储、活到进程结束，故该 `deinit` 不会执行。这是 WAL 模式的正常行为（**数据不丢**：下次打开时 SQLite 自动重放 WAL，读取方始终看到「主库 + WAL」的并集）。
  **已裁决（2026-09-22）：保持现状，仅在文档注明备份注意**。副作用只有一个——只拷 `history.sqlite3` 单个文件会丢掉 `-wal` 里未合并的最近数据。说明已写入 [ARCHITECTURE.md §5.1](ARCHITECTURE.md)、[ARCHITECTURE.en.md §5.1](ARCHITECTURE.en.md) 与 [.trellis/spec/macos/persistence.md](../.trellis/spec/macos/persistence.md) 的 Backup 节。

---

## 5. Bug 报告

### Bug #1 — Wi-Fi 端口永不识别为 `.wifi`

[`InterfaceClassifier.swift` L109-110](file:///Users/dawson/YYProject/private/FlowTrace/FlowTrace/Feature/Interface/InterfaceClassifier.swift#L109-L110)

```swift
let p = port.lowercased()
if p == "wifi" { return .wifi }    // ← 永不命中
```

`"Wi-Fi".lowercased() == "wi-fi"`，含连字符，永不等于 `"wifi"`。

**现场影响（L3-4 + L4-4 双重证实）**：本机 `en1` 是 Wi-Fi，归类为 `.other`；真实运行的 `interface_history` 中**没有 Wi-Fi 桶**。

### Bug #2 — numeric `en*` 永不识别为 `.wired`

[`InterfaceClassifier.swift` L122](file:///Users/dawson/YYProject/private/FlowTrace/FlowTrace/Feature/Interface/InterfaceClassifier.swift#L122)

```swift
if lower.hasPrefix("en") && lower.dropFirst().allSatisfy({ $0.isNumber }) {
```

`dropFirst()` 只去掉 `'e'`，剩下 `"n1"` 含字母 `'n'`，`allSatisfy` 恒为 false。应为 `dropFirst(2)`。

**现场影响**：`en13`、`en7` 等动态接口全部落到 `.other`（L3-3 观测到本机真实使用 en13、en7）。

### Bug #3（本轮新发现）— `bridge*` 的归类与注释不符

同文件 L114 的 `contains("thunderbolt")` 分支**抢先于** L129 的 `bridge` 分支，因为 `portByDevice` 里 `bridge0` 的端口名是 `"Thunderbolt Bridge"`。

- 源码注释与 `InterfaceClassifierTests.testBridgeOther`（用 `portByDevice: [:]`）都声称 `bridge*` → `.other`
- 真实表下实际返回 `.wired`

L3-4 输出证实：`与期望不符的设备：bridge0, en1`（bridge0 即此项）。
严重性低于 #1/#2（归 Wired 尚属合理），但**注释与实现不符**，且上轮的 `testBridgeOther` 因传空表而掩盖了它。

### 修复建议（未执行，等项目决定）

```swift
// Bug #1
if p == "wifi" || p == "wi-fi" { return .wifi }
// Bug #2
if lower.hasPrefix("en") && lower.dropFirst(2).allSatisfy({ $0.isNumber }) { return .wired }
// Bug #3：把 portByDevice 的 bridge 判定提到 thunderbolt 之前，或显式排除含 "bridge" 的端口名
```

修复后需把 F 组 5 个 `XCTAssertNotEqual(.other)` 改回 `XCTAssertEqual(.wifi / .wired)`，并把 `testBridgeOther` 改为传真实形态的表（`["bridge0": "Thunderbolt Bridge"]`）。届时预期 **200 / 200 全绿**。

---

## 6. 测试自身的缺陷（本轮发现并修正，非产品问题）

| # | 缺陷 | 症状 | 修正 |
|---|---|---|---|
| 1 | `let (agg, _, defaults, _) = makeQuotaScenario(...)` 把 `QuotaMonitor` 绑到 `_` | ARC 立即释放 monitor → 其 `cancellables` 释放 → 订阅取消 → 首次「武装」后再无 `check()`，配额永不触发 | 改为强引用绑定 `let (agg, monitor, defaults, _)`，并用 `monitor.config().enabled` 断言保持引用 |
| 2 | `awaitValue(timeout: 2)` | 该 helper 首参无外部标签 → 编译错误 | 改为 `awaitValue(2)` |
| 3 | `XCTAssertTrue(pollUntil(timeout: 4) { ... })` | 尾随闭包嵌在 autoclosure 参数里，编译期标签解析歧义 | 先 `let ok = pollUntil(...)` 再断言 |
| 4 | `echo "…$TOTAL，ERROR…"` | 中文全角逗号紧跟 `$VAR`，bash 把其首字节并入变量名 → `unbound variable` | 改用 `${TOTAL}` 并加空格 |

> 第 1 项最值得记录：它是「测试代码全绿但什么都没测」的典型——若不核对 `firedKeys`，该用例会静默通过。

---

## 7. ⚠️ 隔离缺口（重要发现，需您知情）

计划中把 `CFFIXED_USER_HOME` 当作完整隔离手段。实测证明它**只隔离文件路径，不隔离 `UserDefaults`**。

### 7.1 什么被隔离了（已证实）

| 项 | 结果 |
|---|---|
| `~/Library/Application Support/FlowTrace/` | ✅ 完全隔离：DB/WAL/SHM 全在临时 home；**真实目录 mtime `1788399551` 前后一致** |
| `~/Library/Logs/FlowTrace.log` | ✅ 隔离：日志写在临时 home（`log file=/tmp/flowtrace-e2e-…/Library/Logs/FlowTrace.log`） |

### 7.2 什么**没有**被隔离（已证实）

app 启动日志：

```
INFO [settings] [appearance] applied mode=system
INFO [persistence] history persistence attached at /tmp/…/history.sqlite3; retention=360d
INFO [l10n] init: override=zh-Hans, locale=zh-Hans
```

`retention=360d` 与 `override=zh-Hans` **正是您真实偏好里的值**（已用 `defaults read local.FlowTrace` 复核：`historyRetentionDays=360`、`languageOverride=zh-Hans`）。说明 app 读到的是**真实偏好域**。

**影响评估（低）**：
- L4 全程不修改任何设置，故对偏好**只读**；
- 真实 plist 的 mtime 为 **18:36:25**，而两次 L4 启动分别是 **18:39:52** 与 **18:40:39** —— **L4 的 app 运行没有写入真实偏好**；
- 行为差异：L4 下的保留期/语言/告警开关沿用了您的真实设置（这也是为什么 L4-5 只跑了 1 个分钟桶、日志语言是中文）。

### 7.3 附带发现：18:36:25 那次偏好写入

真实 plist 在 **18:36:25** 被写入，落在 **XCTest 运行窗口内**（早于任何 L4 启动）。写入内容呈现一次性迁移的特征：

```
defaults read local.FlowTrace showMonthInMenuBar   → 不存在
defaults read local.FlowTrace showPeriodInMenuBar  → 1
```

即 `SettingsStore.migrateRenamedDefaultsKeysIfNeeded` 的 `showMonthInMenuBar → showPeriodInMenuBar` 迁移被执行了。

**归因**：测试进程通过 `Loc` / `LocalizationManager.shared` 间接实例化了 `SettingsStore.shared`，后者用 `.standard`（真实域）并执行该迁移。这一路径**自上一轮就已存在**（`LocalizationTests` 调用 `Loc.dateFormatter` 即触发），不是本轮新引入，但本轮把它查实了。

**为什么影响仍可接受**：该迁移是**幂等且设计如此**——它把用户的旧选择搬到新键名上（保留 `true`），app 自己每次启动也会做同样的清理。属于「测试替用户提前执行了 app 自身的正常行为」，不构成偏好损坏。

**若要做到严格隔离**，需要以下之一（本轮未做，留待您决定）：
1. 给 `SettingsStore` / `LocalizationManager` 提供可注入的默认域，并让测试全部走注入路径；
2. 测试进程启动前把真实 plist 快照改名，跑完还原（脚本层，无需改源码）；
3. 让测试避免触碰任何 `.shared` 单例（但 `LocalizationManager.shared` 是 `Loc` 的实现基础，改造成本较高）。

> **文档更正**：`docs/TESTING.md` §0 原写「不会写入用户的真实设置」——该表述不准确，已在文档中更正为「不写真实**数据文件**；偏好域可能被只读访问，且一次性迁移/死键清理可能落到真实域」。

---

## 8. 明确跳过（沿用上轮决定 + 本轮新增）

| 项 | 原因 |
|---|---|
| 3 处 `private` 逻辑的细粒度单测（帧切分、`InterfaceMonitor.parse`、保留期门槛） | **您已裁决不做源码开缝**；其中前两项已由 L3/L4 以真实数据替代验证（见 §3.1/§3.3/§4.2），保留期门槛调度降级为手工 |
| `launchd plist` 真实注册 | 写用户 LaunchAgents 不可逆 → 手工 M21/M22 |
| `networksetup` 权限失败时的分支 | 本机可用，未触发 |
| 菜单栏 UI 渲染、通知投递、发布签名 | 需人工/证书 → 手工 M1–M24 |
| 跨日行为（进程告警跨日重新武装、保留期每日检查点） | 需跨自然日；已由 L1 的 G8（`pruneExpired`）覆盖删除路径，调度门槛留手工 |

---

## 9. 结论与回归建议

### 通过情况

- **L2 27/27、L3 6/6、L4 9/9 全部通过**，L1 除 5 项已知缺陷暴露外全绿。
- 产品代码**零改动**。
- 数据文件隔离**有效**（真实历史库未被触碰）。

### 建议优先级

| 优先级 | 事项 |
|---|---|
| **P0** | 修 Bug #1（Wi-Fi 归类）—— 真实运行下 Wi-Fi 桶缺失，用户可见 |
| **P0** | 修 Bug #2（numeric `en*`）—— 动态接口全落 Other |
| P1 | 修 Bug #3 与注释不符；同时把 `testBridgeOther` 改为真实形态的表，避免再掩盖 |
| P1 | 修正测试套件的偏好副作用（§7.3）：给 `SettingsStore`/`LocalizationManager` 加注入域，或脚本层快照还原真实 plist |
| P2 | 评估退出时是否显式关闭 SQLite 连接（§4.3 观察项） |
| P2 | 手工执行 §6 的 24 项（UI / 通知 / 登录项 / 发布签名） |

### 修复后的预期

修完 Bug #1/#2/#3 → **200 / 200 全绿**。

复现命令：

```bash
xcodegen generate
xcodebuild test -project FlowTrace.xcodeproj \
  -scheme FlowTrace -configuration Debug \
  -derivedDataPath build COMPILER_INDEX_STORE_ENABLE=NO
```

L4 复现：`/tmp/ft-l4-e2e.sh`（`CFFIXED_USER_HOME` 隔离 + 70s 长跑，约 110s）。

---

## 10. 本轮新增/修改的文件

```
FlowTraceTests/
├── TestSupport.swift                      # 新增：awaitValue / pollUntil / 临时库与 suite 基类
├── HistoryPersistenceQueryTests.swift     # 新增 11
├── AlertAndQuotaIntegrationTests.swift    # 新增 5
├── SharedStoreWiringTests.swift           # 新增 3
├── LocalizationResourceTests.swift        # 新增 6
├── RealSubprocessTests.swift              # 新增 6
├── SettingsStoreTests.swift               # +1（19 key 往返）
└── AccentColorTests.swift                 # +1（遗留 key 清理）
docs/
└── TESTING.md                             # §0 隔离表述更正；§7 记录裁决
```

**本次测试未修改任何产品源码。** `git status` 中 `FlowTrace/`、`FlowTraceForMac/`、`project.yml` 显示的改动均为本次会话**之前**已存在的暂存内容（mtime 09-21 17:34 / 09-22 14:13 / 15:50，早于会话开始），与本次测试无关。

---

## 11. 修复记录（Bug #1 / #2 / #3 已修复，**203 / 203 全绿**）

### 11.1 源码改动 —— `InterfaceClassifier.swift`（3 处）

| Bug | 修复 |
|---|---|
| #1 | `if p == "wifi"` → `if p.contains("wifi") \|\| p.contains("wi-fi")` |
| #2 | `lower.dropFirst().allSatisfy { $0.isNumber }` → `let suffix = lower.dropFirst(2); ... !suffix.isEmpty, suffix.allSatisfy { $0.isNumber }` |
| #3 | 把 `lower.hasPrefix("bridge")` 判断**上移**到硬件端口表查询**之前**，使 bridge 的设备名优先于其描述性端口名（`Thunderbolt Bridge`） |

同时更新了文件头部的 Strategy 注释与 [docs/ARCHITECTURE.md](ARCHITECTURE.md) 的判定优先级描述（原写「命中硬件表优先」，已改为「名称启发式先行 → 硬件表 → 动态 en*」）。

### 11.2 测试改动 —— `InterfaceClassifierTests.swift`（11 → 14 项）

- 5 个「bug 暴露」断言（`XCTAssertNotEqual(.other)`）**全部转为正向断言**
- `testBridgeOther` 增加**真实形态**的端口表（`["bridge0": "Thunderbolt Bridge"]`）—— 原来只传空表，正是这一点掩盖了 Bug #3
- 新增 `testRealMachineHardwarePortMatrix`：用本机实测采集的 10 设备端口表逐项锁定归类
- 新增 `testDynamicInterfacesNotInTable`：`en13`/`en7`/`bridge100` 等动态接口
- 新增 `testEthernetPort`、`testBareEnIsNotNumeric`（裸 `en` 不得被当成 numeric 设备）

### 11.3 重跑结果

| 项 | 修复前 | 修复后 |
|---|---|---|
| `xcodebuild test` | 200 例 / **5 失败** | **203 例 / 0 失败** |
| L3-4 真实归类矩阵 | `与期望不符的设备：bridge0, en1` | **`与期望不符的设备：无`** |
| L4 应用级端到端 | 9/9 PASS | **9/9 PASS**（无回归） |

### 11.4 修复生效的**直接实证**（L4 运行时数据）

**① app 运行时真的读到了 Wi-Fi 端口名**（这正是 Bug #1 的触发条件）：

```
ports=["en2": "Thunderbolt 1", "en0": "Ethernet", "en3": "Thunderbolt 2",
       "en4": "Thunderbolt 4", "en6": "Ethernet Adapter (en6)",
       "en10": "Ethernet Adapter (en10)", "en11": "iPhone USB",
       "bridge0": "Thunderbolt Bridge", "en5": "Ethernet Adapter (en5)",
       "en1": "Wi-Fi"]
```

**② 库里第一次出现了 `Wi-Fi` 桶**。修复前的 L4 分布只有 `Wired` 与 `Local Direct`（**完全没有 Wi-Fi**，即 §4.2 记录的现象）；修复后 70s 长跑的 `interface_minute`：

| category | rows | sum_in_bytes | sum_out_bytes |
|---|---|---|---|
| **Wi-Fi** | 2 | 0 | 0 |
| Wired | 2 | 562341 | 264287 |
| Local Direct | 2 | 0 | 0 |
| Other | 2 | 540 | 512 |

四个桶**全部出现**，与分类契约一致。（`Wi-Fi` 行字节为 0 是因为该分钟 en1 只有极小/单向流量；**桶本身出现即证明归类正确**。）

**③ `Other` 桶的占比大幅下降**。修复前 `en1` 与 `en13` 都落 `Other`；修复后 `en13`/`en7` 正确归 `Wired`、`en1` 归 `Wi-Fi`，`Other` 只剩 `bridge100`/`bridge0` 这类真正的桥接设备（同一轮 `interface_history`：`Other` 仅 2 行 1080 B，而 `Wired` 81 行 3.6 MB）。

> 说明：8s 窗口的 `interface_history` 该轮恰好没有 en1 流量，故其中无 `Wi-Fi` 行；70s 长跑的 `interface_minute` 捕捉到了。这不是缺陷，而是「有没有流量」的区别。

### 11.5 修复后仍存在的（未处理，供您决定）

| 项 | 说明 |
|---|---|
| ~~§4.3 观察项：退出后 WAL 未合并~~ | **已裁决：保持现状，仅在文档注明备份注意**（见 §4.3 与三处文档的 Backup 说明）。不改代码 |
| §7.3 测试套件的偏好副作用 | 测试进程经 `Loc`/`LocalizationManager.shared` 间接实例化 `SettingsStore.shared`（`.standard`），一次性键迁移可能落到真实域。需要注入域或脚本层快照还原 |
| §9 手工 24 项 | UI / 通知 / 登录项 / 发布签名 |

---

## 12. 通知链路修复（同日第二轮）

> 起因：核查「配额与告警到底会不会触发通知」，发现两个互不相干但都导致「永远收不到」的缺陷。
> 探针实测（测试宿主即 `local.FlowTrace`，读到的是 app 自己的通知设置）：
> `authorizationStatus = denied(1)`，而 `UNUserNotificationCenter.add(_:)` **仍返回 `error == nil`** ——
> 失败完全不可见，这正是原实现把「没送到」当成「已送达」的根因。

### 12.1 修复的三个问题

| # | 问题 | 证据 | 修复 |
|---|---|---|---|
| 1 | **配额功能从未运行** | `SharedStore.quotaMonitor` 全项目只被声明处与 `DataCleaner` 引用；它是惰性 `static let`，启动路径不触碰 → `init` 不执行 → 永不订阅 → `check()` 从未被调用。同期本月已用 30.1 GiB > 28 GiB 限额，`quotaFiredKeys` 却不存在、日志 0 条配额记录 | 新增 `QuotaMonitor.bootstrap()`，由 `AppDelegate` 在启动时调用 |
| 2 | **投递失败被当成成功记账** | `add(request)` 无 completion；`firedKeys.insert` / `process_alert` 落库都在投递之前或不管成败 | 新增 `LocalNotification`：先查 `authorizationStatus` 再 `add`，返回真实布尔。配额「成功才记 firedKey」，告警「成功才写去重行」，被拒时 15 分钟退避重试 |
| 3 | **权限只在拨动开关时申请** | `SettingsQuotaPane` / `SettingsAlertsPane` / `SettingsStoragePane` 三处 `if on { …requestAuthorization() }`；开关已是 ON 就永不申请。叠加 ad-hoc 签名每次重建换身份（`ncprefs` 里 `local.FlowTrace` 有 **114 个签名身份**），授权极易失效 | `AppDelegate.requestNotificationAuthorizationIfNeeded()`：启动时若任一通知功能启用，查一次状态——`notDetermined` 就申请，`denied` 写 **ERROR** 日志 |

### 12.2 改动文件

| 文件 | 改动 |
|---|---|
| `FlowTrace/Feature/Usage/LocalNotification.swift` | **新增**：`NotificationDelivery` 类型别名（注入缝）+ `LocalNotification.deliver`（生产投递） |
| `FlowTrace/Feature/Usage/QuotaMonitor.swift` | `bootstrap()`；`deliver` 注入；投递成功才写 firedKey；失败退避；`postNotification` 带 completion 并记录 `delivered=` |
| `FlowTrace/Feature/Usage/ProcessAlertMonitor.swift` | `deliver` 注入；**先投递、成功后才落去重行**；失败退避；日志加 `delivered=` |
| `FlowTrace/Feature/Settings/DataRetentionController.swift` | 改用统一投递口（该提醒每日重复，无去重需保护，只求不再假装成功） |
| `FlowTraceForMac/AppDelegate.swift` | 启动时调用 `SharedStore.quotaMonitor.bootstrap()`；新增并调用 `requestNotificationAuthorizationIfNeeded()` |
| `FlowTraceTests/AlertAndQuotaIntegrationTests.swift` | 5 个既有用例改注入投递桩；**新增 2 个回归用例**：投递被拒时不得写 firedKey、不得写 `process_alert` |

### 12.3 验证

| 项 | 结果 |
|---|---|
| `xcodebuild test` | **205 / 205 通过**（原 203 + 2 个新回归用例） |
| 真实 app 启动 | 新增 `ERROR [appDelegate] notifications are denied in System Settings → Notifications → FlowTrace; quota and traffic alerts will not be delivered` —— 修复前该状态**完全不可见** |
| **配额链路复活**（关键） | 真实运行 14s 后日志出现：<br>`INFO [settings] quota 80% reached (30.10 GB of 28.00 GB); notification delivered=false`<br>`INFO [settings] quota 99% reached (30.10 GB of 28.00 GB); notification delivered=false`<br>`INFO [settings] quota 100% reached (30.10 GB of 28.00 GB); notification delivered=false`<br>三个阈值（含自定义 99%）全部正确跨越。**修复前这条链路一个字节都不动。** |
| 拒绝投递不落库 | `process_alert` 行数 **153 → 153**（修复后那轮触发了约 20 条告警，全部被拒，未新增任何去重行） |
| 拒绝投递不记账 | `quotaFiredKeys` **仍不存在** —— 因此用户之后放开权限时会立即补上通知 |

### 12.4 需要您做的一步

修复只让「试图通知」变得可见且可重试；**实际送达仍需系统授权**。请到
**系统设置 → 通知 → FlowTrace** 把通知打开。若列表里没有该项，就在 FlowTrace 设置里把配额/告警开关**关掉再打开**，这会触发一次 `requestAuthorization()` 弹出系统对话框。

打开后，由于 `quotaFiredKeys` 仍是空的，下一次 `check()` 会立刻把过期的 80%/99%/100% 三个阈值补发给你（属预期：这些都是已经逾期未报的告警）。

---

## 13. 0.3.0 发布记录（2026-09-23）

构建由用户在 `Terminal.app` 完成（IDE 沙箱无钥匙链访问，无法跑通签名）。

**构建命令**

```bash
cd ~/YYProject/private/FlowTrace
xcodegen generate
xcodebuild build -project FlowTrace.xcodeproj -scheme FlowTrace \
  -configuration Release -derivedDataPath build COMPILER_INDEX_STORE_ENABLE=NO \
  CODE_SIGN_IDENTITY="Dawson" CODE_SIGN_STYLE=Manual
```

**签名身份**：`Dawson`（SHA-1 `BB1394A66CB92A22F19FCE4BA28735122D9807BD`）。这是登录钥匙链里唯一可用 codesigning 身份；自签、未经公证，所以 Gatekeeper 仍会拒——但**身份稳定**（vs ad-hoc 每次构建都换）。

**Verify-before-upload 实测**

| 检查 | 期望 | 实测 |
| --- | --- | --- |
| `lipo -info` | `x86_64 arm64` | ✅ |
| `Format=` | universal | ✅ `Mach-O universal (x86_64 arm64)` |
| `Authority` | `Dawson` | ✅ `Dawson` |
| `flags` | `0x10000(runtime)` | ✅（**不是** `0x10002(adhoc,runtime)`） |
| `TeamIdentifier` | `not set` | ✅ |
| `spctl -a` | `rejected` + `origin=Dawson` | ✅ |
| `.lproj` 数 | 21（+ Base.lproj） | ✅ 22 |

**密钥链 ACL 修复路径**（`errSecInternalComponent` → 自签成功）：

1. 探针 `codesign --force --sign BB1394A66CB92A22F19FCE4BA28735122D9807BD /tmp/probe` 在 IDE 沙箱里失败（沙箱无钥匙链访问，**与 ACL 无关**）。
2. 在 `Terminal.app` 跑 `security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db`，**让钥匙链弹窗要密码**，不要用 `-k '<真密码>'` 的非交互形式（写错就静默失败）。
3. 同一 `Terminal.app` 里再跑探针，期望 `/tmp/probe: replacing existing signature`（**无** `errSecInternalComponent`）。
4. 同一 `Terminal.app` 里跑真正的 `xcodebuild`。

这一条已加入 AGENTS.md 的 `errSecInternalComponent` 段与本文档。

**打包产物**

```bash
VERSION=$(awk '/^[[:space:]]*MARKETING_VERSION:/{sub(/^[^:]+:/,""); gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit}' project.yml)
APP=build/Build/Products/Release/FlowTrace.app
rm -rf dist && mkdir -p dist/dmg
cp -R "$APP" dist/dmg/
ln -s /Applications dist/dmg/Applications
hdiutil create -volname FlowTrace -srcfolder dist/dmg -ov -format UDZO "dist/FlowTrace-${VERSION}.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/FlowTrace-${VERSION}.zip"
shasum -a 256 "dist/FlowTrace-${VERSION}.dmg" "dist/FlowTrace-${VERSION}.zip"
```

**注意**：`project.yml` 是 YAML，**不能用 `plutil`**——`plutil` 当二进制/text 都失败时，会把整个文件当一行传入下游变量。`awk` 取 `MARKETING_VERSION:` 后字段才是稳的。

| 文件 | 大小 | SHA-256 |
| --- | --- | --- |
| `dist/FlowTrace-0.3.0.dmg` | 3.9 MB | `017839a3a57322e28e269611d800425ec36dd81b91b7d517b9db5cea845fef13` |
| `dist/FlowTrace-0.3.0.zip` | 3.5 MB | `d1406dbf0f2264d1658c82e1eec46ab94ff10b59c77cf542c894466ca3e7684e` |

未公证，所以用户首次启动仍要走 README「First launch」的两步放行。GitHub Release notes 里也要再粘一遍那段告知——「damaged」字面读起来像损坏下载，不解释用户可能报成损坏。
