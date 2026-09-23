# FlowTrace 全方位功能测试计划（v2）

> 本文档 v2，取代 v1。相比 v1（以纯函数单测为主），本版重点补上**功能级/行为级**验证：
> 真实子进程、应用级端到端、此前未覆盖的持久化查询 API。
> **仅覆盖我可自主验证的部分**；需人工介入的单列第 6 章，由您独立执行。
> 上一轮执行记录见 [TESTING-RESULT-2026-09-22.md](TESTING-RESULT-2026-09-22.md)。

---

## 0. 测试分层

| 层 | 名称 | 隔离手段 | 判定方式 | 稳定性 |
|---|---|---|---|---|
| **L1** | 单元 / 纯函数 | 注入 + 临时目录 | XCTest 断言 | 稳定 |
| **L2** | 集成（真实依赖替身 + 临时 SQLite） | `SharedStore` 换装 + 临时 DB | XCTest 断言 | 稳定 |
| **L3** | 真实子进程（nettop / networksetup） | 只读本机命令 | 结构断言 + 信息输出 | 中（依赖本机网络） |
| **L4** | 应用级端到端（启动真实 .app） | **`HOME` 重定向到临时目录** | 进程存活 + DB 落库 + 日志无 error | 中（依赖本机网络） |
| **L5** | 手工交互（UI / 通知 / 登录项 / 发布签名） | — | 人工确认 | 人工 |

**关键新增：L4 的 `CFFIXED_USER_HOME` 隔离法。**

`FlowTrace` 的数据路径全部由 home 推导：
- SQLite → `~/Library/Application Support/FlowTrace/history.sqlite3`（`FileManager` 的 `.applicationSupportDirectory`）
- 日志 → `~/Library/Logs/FlowTrace.log`（`FileManager` 的 `.libraryDirectory`）
- 登录项 plist → `~/Library/LaunchAgents/`（L5 手工，不在 L4 触碰）

**⚠️ 已实测：`HOME` 环境变量在 macOS 上无效。** 写文档时先做了探针验证：

```
HOME=/tmp/ft-probe  →  NSHomeDirectory() = /Users/dawson        ❌ 未跟随
CFFIXED_USER_HOME=/tmp/ft-probe2  →  NSHomeDirectory() = /tmp/ft-probe2
                                     AppSupport = /tmp/ft-probe2/Library/Application Support  ✅
```

macOS 上 `NSHomeDirectory()` 走 `getpwuid()` 而非 `HOME`（这是与 Linux 的关键差异）。因此隔离必须用 CoreFoundation 的 **`CFFIXED_USER_HOME`**（Apple 自己的测试机制）。以

```
CFFIXED_USER_HOME=/tmp/flowtrace-e2e-<uuid>  ./FlowTrace.app/Contents/MacOS/FlowTrace
```

启动，即可跑到**完整真实链路**（真 nettop → 真解析 → 真 SQLite）。

### ⚠️ 隔离边界（L4 执行后实测更正）

`CFFIXED_USER_HOME` **只隔离文件路径，不隔离 `UserDefaults`**：

| 项 | 是否隔离 | 证据 |
|---|---|---|
| `~/Library/Application Support/FlowTrace/`（DB/WAL/SHM） | ✅ 隔离 | 真实目录 mtime 前后一致 |
| `~/Library/Logs/FlowTrace.log` | ✅ 隔离 | 日志落在临时 home |
| `UserDefaults`（`local.FlowTrace`） | ❌ **未隔离** | app 日志显示 `override=zh-Hans`、`retention=360d`，与真实偏好一致 |

**影响与应对**：
- L4 全程不修改设置，故对偏好只在**只读**层面泄漏；真实 plist mtime 早于所有 L4 启动，证明 L4 的 app 未写入偏好。
- 但代价是 L4 的行为**继承您真实设置**（保留期 360d、语言 zh-Hans、告警开关等）。若某用例需要特定设置状态，必须显式说明「依赖运行者的真实偏好」，不能假装是默认值。
- 另外：测试进程通过 `Loc` / `LocalizationManager.shared` 会间接实例化 `SettingsStore.shared`（`.standard`），其**一次性键迁移**可能落到真实域（详见结果文档 §7.3）。这是**测试套件自身**的副作用，与 L4 无关，修复方案见结果文档 §9。

> 因此本计划中「不碰您的数据/偏好」的准确说法是：**不写真实数据文件；偏好域不写（除 `SettingsStore.shared` 的一次性迁移与死键清理外），但会被读取**。

---

## 1. 测试范围与数量

| 层 | 内容 | 用例数 |
|---|---|---|
| L1 | 已有单测 + 修复后新增的回归用例 | 170 |
| L2 | 集成补充：查询 API、告警端到端、本地化/设置全量 | 27 |
| L3 | 真实子进程与命令 | 6 |
| L4 | 应用级端到端 | 9 |
| **自主合计** | **203 + 9** | **203**（一次 `xcodebuild test`）+ 9（L4 场景） |
| L5 | 手工（您执行） | 24 |

> 实际执行结果：**203 / 203 通过**（原计划 206 项，其中 L2 实做 27 项、F 组因修复新增 3 项回归用例）。

---

## 2. L1 — 已有单测（167 例） + 修复后回归（+3）

| 组 | 文件 | 例数 | 状态 |
|---|---|---|---|
| B | SearchFilterTests / ListViewModelSortTests / ListViewModelMergeTests | 5 / 10 / 6 | 全过 |
| C | NetworkParserTests / UsageAggregatorTests / ProcessUsageAggregatorTests | 5 / 2 / 7 | 全过 |
| D | QuotaMonitorTests | 17 | 全过 |
| E | ProcessAlertMonitorTests | 9 | 全过 |
| F | InterfaceClassifierTests | 14 | **全绿**（3 个真实缺陷已修复，含真实机器矩阵回归用例） |
| G | HistoryPersistenceTests / HistoryHeatmapPersistenceTests | 12 / 6 | 全过 |
| H | LocalizationTests / AccentColorTests / AccentDateFieldTests | 14 / 12 / 5 | 全过 |
| I | SettingsStoreTests / DataCleanerTests | 6 / 5 | 全过 |
| K | RingBuffer / UtilsFormatBytes / CSVExporter / AlertLogModel / ProcessUsageModelRange / InterfaceMinuteAggregator / HistoryStore / InterfaceModel | 6 / 6 / 4 / 4 / 3 / 4 / 4 / 4 | 全过 |

**L1 本轮不重跑基线，只在末尾随全量一起跑**（一次 `xcodebuild test` 覆盖）。

---

## 3. L2 — 集成补充（24 项，全自动）

### 3.1 持久化查询 API 补全（10 项）

上轮 G 组覆盖了写路径与 5 个读方法；以下读方法**从未被任何测试调用过**。

文件：新增 `HistoryPersistenceQueryTests.swift`（临时 DB）

| ID | 方法 | 用例 | 期望 |
|---|---|---|---|
| L2-1 | `usageBytes(fromBucket:toBucket:)` | 插 3 桶数据 | 返回 in/out 总和，区间半开 |
| L2-2 | `usageBytes` 空区间 | 查未覆盖范围 | `UsageBytes()` 全 0，不崩 |
| L2-3 | `historyUsageBytes(fromMs:toMs:)` | 插帧 | SUM(bps) = 各帧之和；半开区间 |
| L2-4 | `historyUsageBytes` 边界 | `to < from` | 返回 (0,0) |
| L2-5 | `todayProcessTotals(fromBucket:)` | 跨多桶同进程 | 按 name_key 汇总，起点含在内 |
| L2-6 | `dailyProcessTotals(fromBucket:toBucket:)` | 跨 3 个自然日 | 按 `[nameKey][day]` 分组，day = bucket/1440 |
| L2-7 | `countRange(fromMs:toMs:fromBucket:toBucket:)` | 插已知行数 | 计数 = 4 表之和，与 `deleteRange` 返回值一致 |
| L2-8 | `expiredRowCount(cutoffMs:cutoffBucket:)` | 插新旧行 | 只计过期行；与 `pruneExpired` 删除数一致 |
| L2-9 | `exportProcessUsage` / `exportInterfaceMinute` | 插行后导出 | 行数一致、`time` 由 `date(fromLocalMinuteBucket:)` 还原、按 bucket 升序 |
| L2-10 | `date(fromLocalMinuteBucket:)` 往返 | 指定 bucket | 与 `ProcessUsageAggregator.bucket(of:)` 互逆（±60s） |

### 3.2 告警与配额端到端（5 项）

上轮 E6/E7（Daily 去重、跨日重新武装）与 D 组 fire 路径未真正跑通。

文件：新增 `AlertAndQuotaIntegrationTests.swift`（临时 DB + 注入）

| ID | 用例 | 步骤 | 期望 |
|---|---|---|---|
| L2-11 | 进程告警真实落库 | 临时 DB 挂到 `SharedStore`；`feed` 累计超 floor 的帧 ×N；等待 check 周期 | `process_alert` 出现 1 行，方向 = "in" |
| L2-12 | 同日同向去重端到端 | L2-11 后继续 feed，再等一个 check 周期 | 仍只有 1 行（UNIQUE 生效） |
| L2-13 | 反方向独立入账 | 再让 out 方向超阈值 | 新增 1 行 direction="out"，总计 2 行 |
| L2-14 | 配额 fire 写入 firedKeys | 注入 aggregator + 临时 defaults；直接写 `today` 触发跨阈值 | defaults 里 `quotaFiredKeys` 含 `"<periodKey>:80"` |
| L2-15 | 配额周期滚动后重新武装 | 手动改 defaults 的 key 为上一周期 | 同数值再次可 fire |

> 说明：`ProcessAlertMonitor.check` 有 60s 节流，L2-11 通过注入 `now` 跨越 60s（`feed(entities:interval:now:)` 的 `now` 可传入），避免真实等待。

### 3.3 SharedStore 装配与降级（4 项）

文件：新增 `SharedStoreWiringTests.swift`

| ID | 用例 | 期望 |
|---|---|---|
| L2-16 | `attachHistoryPersistence(_:)` 换装 | `historyPersistence` 非 nil；`historyStore` 被替换为带持久化的新实例 |
| L2-17 | 换装后 `historyStore.append` 落库 | 临时 DB 出现 `history` 行 |
| L2-18 | `DataCleaner.resetInMemory()` 在换装后调用 | 内存清空、**磁盘行保留**（磁盘删除归 Settings 的 `deleteRange`） |
| L2-19 | nil 持久化的降级（消费者层） | `HistoryStore(capacity:persistence:nil)` / `ProcessUsageAggregator { nil }` / `InterfaceMinuteAggregator(…, persistence: nil)` 全都不崩且不写盘 |

> **进程级副作用（必须登记）**：`SharedStore.historyPersistence` 是 `static private(set) var`，唯一的写入入口是 `attachHistoryPersistence(_:)`，**只能 nil → 实例，无法还原为 nil**。因此 L2-16/17/18 一旦执行，本进程内 `SharedStore.historyStore` 就永久带上持久化。
> 应对规则：
> 1. 这三项使用一个**不删除**的临时 DB（避免后续 append 写到已删除的路径）；
> 2. 全套测试中**不得存在**断言 `SharedStore.historyPersistence == nil` 的用例（当前无，新增时须检查）；
> 3. L2-19 因此**不改 `SharedStore`**，只在消费者层用 nil 构造，验证降级路径。

### 3.4 本地化与设置全量（5 项）

文件：补强 `LocalizationTests.swift`、`SettingsStoreTests.swift`

| ID | 用例 | 期望 |
|---|---|---|
| L2-20 | 21 个 locale 逐一 `string("Settings")` | 均非空、非 key 本身、非 sentinel |
| L2-21 | 缺 key 回退 | 取一个不存在的 key → 返回 key 本身（而非空串） |
| L2-22 | `Loc.appDisplayName` 分支 | zh 前缀 → 走 InfoPlist 表；英文 → "FlowTrace" |
| L2-23 | `SettingsStore` 20 key 全量 round trip | 逐个写非默认值 → 新建实例读回一致 |
| L2-24 | `AccentColorManager` legacy key 清理 | 预设 `accentMode`/`accentRGBA`/`accentFollowSystem` → init 后被删除 |

---

## 4. L3 — 真实子进程与命令（6 项）

目的是验证「nettop 的真实输出格式」与「分类器拿到的真实硬件表」——这是纯函数测不到、mock 也无法证伪的部分。

> 依赖本机网络与 `/usr/bin/nettop` 存在。采集失败时**记为 SKIP 而非 FAIL**（附原因），不阻塞整体结果。

### 4.1 命令行工具冒烟（3 项）

文件：`RealSubprocessTests.swift`（XCTest）

| ID | 用例 | 步骤 | 期望 |
|---|---|---|---|
| L3-1 | nettop 可执行 | `FileManager.isExecutableFile(/usr/bin/nettop)` | true（否则 SKIP） |
| L3-2 | per-process 帧格式 | 自己 spawn `script -q /dev/null nettop -P -d -L 0 -J bytes_in,bytes_out -t external -s 1 -c`，读 3~5 行 | 每行 CSV ≥3 列；col0 形如 `name.pid`；col1/col2 可解析为整数 |
| L3-3 | socket 帧格式 | 同上但 `-J bytes_in,bytes_out,interface` | 每行 ≥4 列；**存在 interface 非空的行**，也**存在 interface 为空的行**（后者正是 `InterfaceMonitor.parse` 必须跳过的进程汇总行——直接印证注释所述 2× 翻倍风险的来源） |

### 4.2 真实硬件端口表（1 项 + **已采集的真实现场数据**）

| ID | 用例 | 步骤 | 期望 |
|---|---|---|---|
| L3-4 | `InterfaceClassifier.discoverPortByDevice()` | 直接调用 | 返回非空 dict；含 `en0`/`en1` 之一；value 为端口名；**输出实际 dict 供比对** |

**已在本机采集的真实输出**（写文档时的探针，非测试执行）：

```
Hardware Port: Ethernet                    Device: en0
Hardware Port: Ethernet Adapter (en5)      Device: en5
Hardware Port: Ethernet Adapter (en6)      Device: en6
Hardware Port: Ethernet Adapter (en10)     Device: en10
Hardware Port: Thunderbolt Bridge          Device: bridge0
Hardware Port: Wi-Fi                       Device: en1        ← 本机 Wi-Fi
Hardware Port: Thunderbolt 1               Device: en2
Hardware Port: Thunderbolt 2               Device: en3
Hardware Port: Thunderbolt 4               Device: en4
Hardware Port: iPhone USB                  Device: en11
```

把这 10 项逐一代入 `classify`，得到**真实的归类矩阵**（期望 vs 现状）：

| Device | Hardware Port | 期望 | 现状 | 结论 |
|---|---|---|---|---|
| en0 | Ethernet | .wired | .wired | ✅ |
| en5/en6/en10 | Ethernet Adapter (…) | .wired | .wired | ✅（含 "ethernet"） |
| **en1** | **Wi-Fi** | **.wifi** | **.other** | ❌ **Bug #1：本机 Wi-Fi 被标成 Other** |
| en2/en3/en4 | Thunderbolt N | .wired | .wired | ✅ |
| en11 | iPhone USB | .wired | .wired | ✅ |
| **bridge0** | **Thunderbolt Bridge** | **.other**（按源码注释） | **.wired** | ⚠️ **Bug #3（新发现）：命中 "thunderbolt" 抢先于 bridge 分支** |

> **Bug #3**：源码注释与 `F7` 测试都声称 `bridge*` 归 `.other`，但 `classify` 先用 `portByDevice` 命中 `"Thunderbolt Bridge"` → `contains("thunderbolt")` → 返回 `.wired`，**bridge 名称分支永远走不到**（本机 bridge0 就是实例）。严重性低于 #1/#2（归 Wired 尚属合理），但注释与实现不符，且 F7 测试用的是 `portByDevice: [:]`，掩盖了这一点——L3-4 补上了真实表这一维度。

> **Bug #1 的严重性现已确证**：本机 `en1` 是真 Wi-Fi，`classify("en1")` 返回 `.other`。也就是说 **popover 的接口概览会把用户的 Wi-Fi 归到 Other 桶**，而 Wi-Fi 通常是主要流量来源。这是用户可见的功能缺陷，不是理论问题。

### 4.3 首帧语义（2 项，信息性）

| ID | 用例 | 步骤 | 期望 |
|---|---|---|---|
| L3-5 | 首帧为累计值 | 采集 3 帧，比较首帧与后续帧的字节量级 | 首帧显著大于后续（或记录实际比例），**仅作信息输出**，不硬断言 |
| L3-6 | 帧间隔符合 `-s 1` | 记录 3 帧到达时刻 | 间隔 ≈1s（±0.6s），验证 `-s` 生效 |

---

## 5. L4 — 应用级端到端（9 项）

启动**真实构建的 .app 二进制**，`CFFIXED_USER_HOME` 重定向到临时目录，观察真实数据链路。

```
E2E_HOME=$(mktemp -d /tmp/flowtrace-e2e-XXXXXX)
# 安全闸：必须是 /tmp 下的路径，否则拒绝执行
case "$E2E_HOME" in /tmp/*) ;; *) echo "refuse"; exit 1;; esac

CFFIXED_USER_HOME="$E2E_HOME" ITRAFFICPLUS_FILE_LOG=1 \
  build/Build/Products/Debug/FlowTrace.app/Contents/MacOS/FlowTrace &
APP_PID=$!
trap 'kill $APP_PID 2>/dev/null' EXIT
```

| ID | 用例 | 步骤 | 期望 |
|---|---|---|---|
| L4-1 | 冷启动存活 | 启动后等 8s | 进程仍在（`kill -0 $APP_PID`）；无崩溃 |
| L4-2 | 隔离生效 | 检查 `$E2E_HOME/Library/Application Support/FlowTrace/` | 目录与 `history.sqlite3` 出现在**临时 home 下**；真实 `~` 未被写入（对比前后 mtime） |
| L4-3 | `history` 表落库 + **首帧丢弃复核** | `sqlite3 "$E2E_HOME/.../history.sqlite3" "select count(*), min(in_bps), max(in_bps) from history"` | 行数 > 0（证明 nettop → parser → historyStore → SQLite 全链路通）；**首行量级须与后续行同阶**——若首帧未被丢弃，首行会是启动以来累计值，量级高出 2~3 个数量级。结果文档打印首行与其余行的数值对比 |
| L4-4 | `interface_history` 落库 + 量级交叉核对 | 同上查 `interface_history` 的 `count(*)` 与 `sum(in_bps)` | 行数 > 0（证明第二个 nettop + 分类器 + 落库通）；`sum(in_bps)` 与 `history` 的 `sum(in_bps)` **同量级**（相差 <10×）——若空 interface 行未被跳过，接口侧会系统性地约为进程侧的两倍 |
| L4-5 | `process_usage` 分钟 flush | **运行 70s** 后再查 | > 0（覆盖跨分钟 flush 的真实路径） |
| L4-6 | 日志无 ERROR | 查 `$E2E_HOME/Library/Logs/FlowTrace.log` | **无 ` ERROR [` 行**（行格式为 `<ISO8601> LEVEL [category] msg`，级别是大写 `DEBUG`/`INFO`/`ERROR`） |
| L4-7 | 优雅退出 | `SIGTERM` → 等 3s | 进程消失；`-wal` 被合并/清理 |
| L4-8 | 重启 bootstrap | 再次启动同一 `E2E_HOME`，8s 后查日志 | 出现 `bootstrap: seeded N frames`，N > 0（证明重启后 sparkline 不空） |
| L4-9 | 窗口路径冒烟 | `FLOWTRACE_OPEN=history` / `=settings` 各启动一次 | 进程存活 ≥5s，不崩（AppDelegate 已有该 env 开关） |

> `ITRAFFICPLUS_FILE_LOG=1` 显式打开文件日志——Debug 构建默认已开，显式指定以免将来 Release 配置改变导致 L4-6 静默失效。
> L4-5 需要 70s，是全套测试里最慢的一项，标记为「可选长跑」：默认执行，可用参数跳过。
> 所有 L4 用例结束后删除 `$E2E_HOME`；**绝不使用真实 HOME**（由上面的 `case` 闸门强制）。

---

## 6. L5 — 需您手工验证（24 项，不计入自主测试）

> AI 无法自主验证：依赖真实交互、系统 UI、磁盘副作用、发布者证书。

### 6.1 菜单栏与 popover（6 项）

| ID | 用例 | 步骤 | 期望 |
|---|---|---|---|
| M1 | 点击弹出 | 点状态栏图标 | 300ms 内出现，含进程列表 + 接口概览 + sparkline |
| M2 | 四段开关 | 分别关 `showDownloadInStatusBar` / `showUpload` / `showToday` / `showPeriod` | 对应段消失，菜单栏宽度随之收缩，不出现省略号 |
| M3 | 进程搜索 | 输入 `chrome` / 输入 PID | 命中正确；`×` 清空后恢复全量 |
| M4 | 排序切换 | 六种排序切换 | 顺序正确；「今日」列有值后累计排序生效 |
| M5 | sparkline | 持续跑流量 60s+ | 曲线填充；峰值/均值/累计与菜单栏数字一致 |
| M6 | 深度休眠 | 关闭 popover 静置 ~35s 再打开 | 重新出现且曲线连续（controller 被释放后重建） |

### 6.2 设置窗口（6 项）

| ID | 用例 | 期望 |
|---|---|---|
| M7 | 五个 tab 切换 | 窗口尺寸随之变化，无裁切；tab 高亮为中性色（不跟随强调色） |
| M8 | 文本字段提交 | 输入后按 Return / 切 tab / 直接关窗，三种路径都必须保存（AGENTS.md 记录的 teardown 陷阱） |
| M9 | AppKit 控件宽度 | 法语、俄语下打开：segmented picker 与 switch 不溢出/不重叠 |
| M10 | 外观切换 | 系统/浅/深 立即生效；popover 缓存窗口同步 |
| M11 | 强调色 | 自定义 hex 在 popover / 设置 / 历史窗三处 SwiftUI 控件生效；`#XYZ` 失焦红框并还原 |
| M12 | 清空数据 | 确认后 UI 立刻空，磁盘行也确实删除（`sqlite3` 复核） |

### 6.3 历史窗口（5 项）

| ID | 用例 | 期望 |
|---|---|---|
| M13 | App usage 页 | 排序、范围过滤、CSV 导出内容与屏幕一致 |
| M14 | 热力图 | 两种布局（dayPerRow / dayPerColumn）切换正常；hover 明细正确；类别勾选过滤生效 |
| M15 | Alert log | 六列排序；范围含 All；CSV 导出的 Factor 在零基线时为空 |
| M16 | 三个自定义日期选择器 | 本地化月历；不能选未来日期；切换语言后表头立即变 |
| M17 | 窗口最小尺寸 | 680×560 下三页都不裁切 |

### 6.4 通知与权限（3 项）

| ID | 用例 | 期望 |
|---|---|---|
| M18 | 配额通知 | 调小限额跨 80% → 弹出一次；同周期不重复 |
| M19 | 进程异常通知 | 每进程每方向每日一条；正文倍数/量级正确 |
| M20 | 拒绝权限 | 系统关闭通知 → UI 不崩、静默，数据仍入库 |

### 6.5 登录项与发布（4 项）

| ID | 用例 | 期望 |
|---|---|---|
| M21 | Launch at login（macOS 11–12） | `~/Library/LaunchAgents/local.FlowTrace.login.plist` 存在，RunAtLoad=true，路径指向当前 .app；关闭后文件消失 |
| M22 | Launch at login（macOS 13+） | `SMAppService.mainApp.status == .enabled` |
| M23 | Release 产物体检 | `lipo -info` = `x86_64 arm64`；`codesign` 有 Authority；`spctl` rejected（未公证属预期） |
| M24 | 首次启动放行 | 双击 .dmg 安装 → 按 README 放行后成功启动 |

---

## 7. 源码开缝 —— **已裁决：不批准，跳过**

有 3 处逻辑被 `private` 封闭，需改源码（提取纯函数）才能单测。**您已裁决：不做任何源码改动。**

| 位置 | 现状 | 原拟改动 | 处置 |
|---|---|---|---|
| `NettopRunner.flushFrame / consume` | private，需真子进程才能驱动 | 提取帧切分 + 首帧丢弃为 internal 纯函数 | **跳过** |
| `InterfaceMonitor.parse` | private | 提升为 internal | **跳过** |
| `DataRetentionController.dayKey` / 门槛判定 | private，与 Timer、单例耦合 | 提取 `shouldRun(...)` | **跳过** |

### 因此：这三处的正确性改为「外部现象间接验证」

| 原拟单测点 | 替代验证手段 | 是否足够 |
|---|---|---|
| 首帧丢弃（累计值不入库） | **L4-3**：真实运行 8s 后 `history` 表的**首行数值量级**应远小于累计值；若首帧未被丢弃，首行会是进程启动以来的累计字节，量级明显异常（结果文档中会打印首行与其他行的量级对比） | 足够（有真实数据作证） |
| 空 interface 行跳过（2× 翻倍） | **L3-3**：直接证明真实输出中**同时存在** interface 为空与不为空的行 → 印证需跳过的前提；**L4-4**：`interface_history` 的数值与 `history` 总量做量级交叉核对 | 足够 |
| `-s 1` 间隔生效 | **L3-6**：真实帧到达间隔 ≈1s | 足够（优于单测） |
| 每日保留期门槛（跨日/同日不重复） | **L4** 隐含覆盖不了（需跨日）；改由 **L1 的 G7/G8**（`prune` / `pruneExpired` 的删除路径）+ 您手工 **M12** 覆盖 | **降级**：门槛调度本身不再自动验证，仅记入 L5 |

> **代价登记**：约 6 项细粒度用例不产出。其中 3 项（首帧丢弃、空 interface、帧间隔）改由真实数据验证，**可信度反而高于 mock**；1 项（保留期门槛调度）降级为手工。这是本次不做源码改动的净损失。

---

## 8. 通过标准

| 层 | 标准 |
|---|---|
| L1 | **203 例全绿**（InterfaceClassifier 的 3 个真实缺陷已修复，见结果文档 §5/§11） |
| L2 | 24/24 全绿 |
| L3 | 断言项全绿；依赖本机网络的采集项允许 SKIP（需写明原因） |
| L4 | 9/9 全绿（L4-5 长跑若跳过需注明） |
| L5 | 您人工确认 |

**整体判定**：L1 除已知 bug 外全绿 + L2 全绿 + L3 无 FAIL + L4 全绿，即视为通过。

---

## 9. 执行顺序与产物

```
L1（167 例单测，一次 xcodebuild test 跑完）
  └─→ L2（同一次 test run，新增测试文件）
        └─→ L3（真子进程，同一次 test run；采集失败 SKIP）
              └─→ L4（脚本驱动真实 .app，HOME 隔离）
                    └─→ L5（人工）
```

产物：
1. `docs/TESTING-RESULT-<date>.md` — 四层结果、SKIP 清单、Bug 报告、回归建议
2. L3 的**真实命令输出样本**（nettop 原始帧、hardwareports 表）附在结果文档里，作为证据

---

## 10. 风险与隔离

| 风险 | 缓解 |
|---|---|
| L4 写入您的真实数据 | **强制 `CFFIXED_USER_HOME` 重定向**（已验证有效；`HOME` 无效）；脚本内 `case` 闸门断言路径以 `/tmp/` 开头，否则拒绝执行；L4-2 专门复核真实 `~` 未被写入 |
| L2 `SharedStore` 换装是**不可逆**的进程级副作用 | 见 §3.3 三条规则：临时 DB 不删除、禁止任何 `historyPersistence == nil` 断言、降级用例只走消费者层 |
| `xcodebuild test` 在沙箱 shell 中受限 | 全程 `-derivedDataPath build COMPILER_INDEX_STORE_ENABLE=NO` |
| L3/L4 依赖本机网络 | 采集为空记 SKIP；断言只看**结构**不看**数值** |
| L4 启动的 app 残留进程 | 脚本 `trap` 兜底 `kill`；结束检查 `pgrep` |
| L4-5 需 70s | 标记可选，默认执行、可跳过 |
| 真子进程在 CI 环境可能被杀 | L3/L4 定位为「本机功能验证」，不假设可在任意 CI 复现 |
| `networksetup` 需权限 | 只读命令；失败即 SKIP |
| L3/L4 的 `nettop` 子进程可能拖慢机器 | 采集窗口 ≤5s；L4 单次运行 ≤10s（除 L4-5）|
| `CFFIXED_USER_HOME` 若被系统忽略，L4 会写到真实 `~` | L4-2 首次即断言临时目录下出现 DB 且真实目录 mtime 未变；一旦不成立**立即中止后续 L4**，不再执行 |

---

## 11. 与上一轮的差异（复审结论）

上一轮（167 例）覆盖了纯函数与持久化写路径，本轮补齐：

1. **从未被调用过的 7 个持久化读 API**（`usageBytes` / `historyUsageBytes` / `todayProcessTotals` / `dailyProcessTotals` / `countRange` / `expiredRowCount` / 两个 export）
2. **告警与配额的 fire 路径**（上轮只测了纯函数 `decide` / `shouldFire`，没测真正写库）
3. **真实子进程**（上轮把 `NettopRunner`/`InterfaceMonitor` 整体排除，本轮改为「外部现象 + 格式结构」验证）
4. **应用级端到端**（上轮完全没有；本轮用 `CFFIXED_USER_HOME` 隔离法实现）
5. **本地化 21 语言全量表加载**（上轮只抽样了 "Settings" 一个 key）
6. **SharedStore 装配/拆除**（上轮未触碰单例换装）

### 写文档时的前置探针（已执行，属方案验证）

为避免提出不可行的方案，写本文件时先跑了 3 个只读探针，结果直接影响了方案：

| 探针 | 结论 | 对方案的影响 |
|---|---|---|
| `HOME=/tmp/x` 是否重定向 home | **否**（macOS 走 `getpwuid`） | L4 隔离手段改为 `CFFIXED_USER_HOME` |
| `CFFIXED_USER_HOME=/tmp/x` | **是**（NSHomeDirectory 与 AppSupport 均跟随） | L4 方案成立 |
| `networksetup -listallhardwareports` 真实输出 | 本机 `en1` = Wi-Fi；`bridge0` = Thunderbolt Bridge | **新增 Bug #3**；并把 Bug #1 从「理论问题」确证为「本机 Wi-Fi 会被标成 Other」 |

> 注意：这 3 项是**方案可行性验证**，不是测试执行；正式的 L3/L4 结果将在您批准后产出。

---

## 12. 裁决记录与开工条件

### 已裁决（本次）

| 议题 | 裁决 | 文档处置 |
|---|---|---|
| §7 源码开缝（3 处 private） | **不批准** | §7 改为「跳过」并登记替代验证与净损失；**全程不改产品代码** |
| L4-5 的 70s 长跑 | **保留** | 默认执行，不跳过 |
| 分层方案 L1–L5 | 待您确认文档整体 | — |

### 待确认后即开工的检查清单

执行前会先复核以下 4 条，任一不满足即停下报告：

1. `xcodegen` / `xcodebuild` 可用（Xcode 16.4 已确认）
2. `CFFIXED_USER_HOME` 在本机仍生效（已探针确认，执行前复测一次）
3. `/usr/bin/nettop` 与 `/usr/sbin/networksetup` 可用（已确认）
4. 真实 `~/Library/Application Support/FlowTrace/` 执行前后 mtime 不变（L4-2 断言）

### 执行产出

1. `docs/TESTING-RESULT-<date>.md`：L1–L4 结果、SKIP 清单、Bug #1/#2/#3 报告、回归建议
2. L3 的**真实命令输出样本**（nettop 原始帧、hardwareports 表）作为证据附入结果文档
3. L4 的**首行量级对比**与**接口/进程总量交叉核对**数值
4. 更新 [TESTING-RESULT-2026-09-22.md](TESTING-RESULT-2026-09-22.md) 的 Bug 清单（加入 Bug #3）

**文档已定稿。您说开始，我即按 §9 顺序执行。**
