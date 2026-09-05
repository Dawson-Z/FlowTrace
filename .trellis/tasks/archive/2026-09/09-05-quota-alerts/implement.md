# Implement — Data quota & threshold alerts

1. [ ] `UsageAggregator.swift`（Feature/Usage/）：tick 节流 + today/month @Published；SharedStore 挂 `usageAggregator`；`Network.handleFrame` 调 tick。
2. [ ] SettingsStore：quotaEnabled / quotaPeriod / quotaLimitGB / quotaCustomPercent + sink。
3. [ ] `QuotaMonitor.swift`：阈值跨越 + UNUserNotificationCenter + fired-keys 去重；AppDelegate 挂单例。
4. [ ] SettingsView：Quota 分区（开关/周期/上限/自定义阈值）。
5. [ ] 通知与设置文案三语（strings）。
6. [ ] `verify_quota.swift`（阈值跨越/去重/periodKey）全 PASS。
7. [ ] 编译 + GUI 验证（1 GB 日配额触发通知）→ changelog + commit + archive。

## Gates
- 字节口径唯一来源 process_usage；主线程无 sqlite。
- 通知去重：同周期同阈值仅一次。
- 开关关闭零开销（monitor 不订阅）。
