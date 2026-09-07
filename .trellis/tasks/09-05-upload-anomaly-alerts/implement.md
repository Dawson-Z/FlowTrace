# Implement — Abnormal upload alerts

1. [ ] SettingsStore：`uploadAlertEnabled` / `uploadAlertMultiplier` / `uploadAlertMinMBps` + sink。
2. [ ] `UploadAnomalyMonitor.swift`：私有队列；每名滑动基线（最近 N 非零上传）、中位数、触发条件（倍数+绝对下限）、连续≥3帧、冷却期。
3. [ ] 接入 `Network.handleFrame`（进程帧喂入，主队列回调）。
4. [ ] `SharedStore.uploadAnomalyMonitor` 单例；AppDelegate 或 Network 挂接。
5. [ ] Settings UI：Upload alerts 分区（开关请求授权 + 灵敏度）。
6. [ ] 三语 strings（Upload alerts / Abnormal upload / 正文）。
7. [ ] `verify_upload_anomaly.swift` 全 PASS。
8. [ ] 编译 + GUI 验证（大上传触发、冷却期不重复）→ changelog + commit + archive。

## Gates
- 状态在私有队列，主线程无竞争；通知去重（进程+冷却期）。
- 开关关闭零开销（不订阅帧）。
- 冷启动（基线未满）不误报。
