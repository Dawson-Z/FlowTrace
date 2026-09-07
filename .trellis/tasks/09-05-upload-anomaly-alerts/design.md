# Design — Abnormal upload alerts

## 1. 目标

检测某程序**上传速率骤增**（相对其近期基线明显异常）时发本地通知，防后台偷传。

## 2. 检测器（`Feature/Usage/UploadAnomalyMonitor.swift` 新建）

挂在 `Network.handleFrame` 的进程帧流上（归一化后的 bps，主队列回调处喂入）。
但其内部状态必须独立于主线程——用**私有串行队列**累积帧。

### 数据模型（纯逻辑，可 standalone 测试）

- 每显示名（`name.lowercased()`）维护一个**滑动基线**：环形数组存最近 N 个非零上传值（默认 N=15 帧 ≈ 30s @2s interval）。
- **触发条件**（同时满足）：
  1. `当前上传 > 基线中位数 × multiplier`（默认 8×）
  2. `当前上传 >= minAbsBytesPerSec`（默认 1 MB/s = 1_048_576，滤掉闲时低流量误报）
  3. 在同一分钟内**连续 ≥ 3 帧**满足 1&2（防毛刺）
  4. 基线已有 ≥ 5 个非零采样（冷启动不判）
- **冷却期**：同一进程通知后 `cooldownSeconds`（默认 30 分钟）内不再触发（进程级独立）。
- 进程名与程序用量同口径（nettop 名，大小写不敏感合并）。

### 阈值可配置（SettingsStore 新增）

| 字段 | 默认 | 说明 |
|---|---|---|
| `uploadAlertEnabled` | false | 总开关 |
| `uploadAlertMultiplier` | 8 | 相对中位数倍数（2…50 Stepper） |
| `uploadAlertMinMBps` | 1 | 绝对下限 MB/s（0.1…100） |

## 3. 通知

`UNUserNotificationCenter`（同 QuotaMonitor 模式）：标题"异常上传"，正文"{程序} 正在高速上传 ({rate}/s)，可能超出预期"。含冷却期去重。

## 4. 设置 UI

Settings 新增 "Upload alerts" 分区：启用开关（开启时请求通知授权）+ 灵敏度（倍数/下限）。放在 Quota 区后。

## 5. 验证

`verify_upload_anomaly.swift`：基线中位数、触发条件（倍数+绝对下限）、连续帧要求、冷却期去重、冷启动不判、空基线。
