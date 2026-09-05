# Design — Data quota & threshold alerts

## 1. 用量口径（与 menubar-display-mode 共享）

`UsageAggregator`（新，`Feature/Usage/UsageAggregator.swift`，ObservableObject 单例挂 `SharedStore`）：

- 数据源：**`process_usage` 表**（字节口径，程序用量 Tab 同源）——`SUM(in_bytes), SUM(out_bytes) WHERE minute_bucket >= periodStartBucket`。选它而非 `history` 速率表的原因：字节口径跨采样间隔（1/2/5 s）安全、重启后完整、与 App usage 数字天然一致。
- `@Published private(set) var today: UsageBytes` / `month: UsageBytes`（`UsageBytes { inBytes, outBytes }`）。
- 节流：`tick()` 由 `Network.handleFrame` 调用；距上次查询 < 15 s 直接返回（查询轻量但避免每 2 s 一次）。
- 周期起点（本地日历）：day = 今日 0 点；month = 本月 1 日 0 点；换算 minute bucket 同 ProcessUsageModel。

## 2. 配额设置（SettingsStore 新增）

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `quotaEnabled` | Bool | false | 总开关；开启时请求通知授权 |
| `quotaPeriod` | String | "month" | month / week / day |
| `quotaLimitGB` | Int | 100 | 上限（GB），1…10000 Stepper |
| `quotaCustomPercent` | Int | 0 | 自定义阈值 %（0 = 关闭；80/100 恒定内置） |

sink 写回 defaults（同现有模式）。

## 3. QuotaMonitor（`Feature/Usage/QuotaMonitor.swift` 新建）

- 订阅 `UsageAggregator` 的 `$today/$month`（按 quotaPeriod 读对应值）。
- 阈值集合 = {80, 100} ∪ {customPercent 若 >0 且 ≠80/100}。
- **跨越检测**：`prevPercent < t && currPercent >= t` → 通知一次；`UserDefaults` 记录 `quotaFiredKeys`（`"\(periodKey):\(t)"`），periodKey = 周期起点 ISO 日期，翻转自然失效。
- 通知：`UNUserNotificationCenter`（App delegate 未做 UNUserNotificationCenterDelegate 也无妨；授权在开启开关时请求）。
- 文案三语：标题 "Quota {p}%" / 正文 "{used} of {limit} ({p}%)"。

## 4. 设置 UI

SettingsView 新增 "Quota" 分区：Enable 开关、Period Picker（Month/Week/Day）、Limit（GB Stepper 1…10000）、Custom threshold Stepper（0–99 %，0=off）。放在 History 区后、Monitoring 前。

## 5. 验证

- `verify_quota.swift`：阈值跨越检测（prev< t ≤ curr）、periodKey 生成、去重、周期翻转——纯逻辑用例。
- GUI：设 1 GB 日配额 + 大流量触发通知；跨天后可再次触发。
