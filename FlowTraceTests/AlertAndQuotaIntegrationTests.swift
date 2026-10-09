//
//  AlertAndQuotaIntegrationTests.swift
//  FlowTraceTests
//
//  L2-11 ~ L2-15：告警与配额的 **fire 路径**端到端。
//  上轮只单测了纯函数 decide / shouldFire，从未验证「判定通过后真的写库 / 真的记账」。
//
//  这两个 monitor 内部读 `SharedStore.historyPersistence`，因此用例会挂一个临时库
//  （见 TestSupport.SharedTestPersistence 与 docs/TESTING.md §3.3）。
//

import XCTest
import SQLite3
@testable import FlowTrace

final class AlertAndQuotaIntegrationTests: TempDefaultsTestCase {

    private let MB = 1024 * 1024

    private func entity(_ pid: Int, _ name: String, inBps: Int, outBps: Int) -> ProcessEntity {
        ProcessEntity(pid: pid, name: name, inBytesPerSec: inBps, outBytesPerSec: outBps)
    }

    // MARK: - 投递桩
    //
    // 测试进程里系统通知权限是 denied（实测 authorizationStatus = .denied），
    // 所以绝不能走真实投递：否则每个用例都会去碰 Notification Center，而且
    // “投递是否成功”这条分支就无法覆盖。注入一个确定性结果，两条路径都能测。

    /// 投递成功（模拟已授权）。
    private let deliveredOK: NotificationDelivery = { _, done in done(true) }
    /// 投递被系统拒绝（模拟权限被关）。
    private let deliveredRefused: NotificationDelivery = { _, done in done(false) }

    // MARK: - L2-11 / L2-12 / L2-13  进程异常告警真实落库

    /// 下载方向：累计超过绝对下限后必须真的写进 `process_alert`。
    func testDownloadAlertIsPersisted() {
        let settings = SettingsStore(defaults: makeDefaults())
        settings.uploadAlertEnabled = true
        settings.alertMinDownloadMB = 1          // 下限 1 MB，便于触发
        settings.alertDownloadMultiplier = 1

        let p = SharedTestPersistence.attach("alert-download")
        let monitor = ProcessAlertMonitor(settings: settings, deliver: deliveredOK)

        // 单帧 2 MB/s × 1s = 2 MB ≥ 1 MB 下限；基线缺失（0）→ 视为异常
        monitor.feed(entities: [entity(90001, "bulk-downloader", inBps: 2 * MB, outBps: 0)],
                     interval: 1, now: Date())

        let ok = pollUntil(timeout: 4) { alertRowCount(p) == 1 }
        XCTAssertTrue(ok, "超阈值的下载告警必须写入 process_alert")

        let records = awaitValue(2) { p.alertRecords(completion: $0) }
        XCTAssertEqual(records?.count, 1)
        XCTAssertEqual(records?.first?.name, "bulk-downloader")
        XCTAssertEqual(records?.first?.isIn, true, "方向必须是 in")
        XCTAssertGreaterThanOrEqual(records!.first!.todayBytes, 2 * MB)
        XCTAssertEqual(records?.first?.baselineBytes, 0, "无 7 日基线 → 0")
    }

    /// 同日同向第二条必须被 UNIQUE 索引拦下（真实去重，而非内存开关）。
    func testSecondAlertSameDaySameDirectionIsRejected() {
        let settings = SettingsStore(defaults: makeDefaults())
        settings.uploadAlertEnabled = true
        settings.alertMinDownloadMB = 1
        settings.alertDownloadMultiplier = 1

        let p = SharedTestPersistence.attach("alert-dedup")
        // 计数投递桩：行去重（UNIQUE 索引）之外，**通知本身**也必须只发一条。
        // 回归：2026-10-09 实测发现原实现只在写行时 INSERT OR IGNORE，
        // 横幅在 60s 检查持续成立时每分钟重发一次（行数恒为 1，测试却绿的）。
        final class DeliveryCounter {
            private let lock = NSLock()
            private var count = 0
            var deliver: NotificationDelivery {
                { _, done in
                    self.lock.lock(); self.count += 1; self.lock.unlock()
                    done(true)
                }
            }
            var notifications: Int {
                lock.lock(); defer { lock.unlock() }
                return count
            }
        }
        let counter = DeliveryCounter()
        let monitor = ProcessAlertMonitor(settings: settings, deliver: counter.deliver)
        let now = Date()

        monitor.feed(entities: [entity(90002, "dup-downloader", inBps: 2 * MB, outBps: 0)],
                     interval: 1, now: now)
        let firstAlertLanded = pollUntil(timeout: 4) { alertRowCount(p) == 1 }
        XCTAssertTrue(firstAlertLanded)

        // 跨过 60s 检查节流，再喂一帧（同一自然日、同一方向）
        monitor.feed(entities: [entity(90002, "dup-downloader", inBps: 2 * MB, outBps: 0)],
                     interval: 1, now: now.addingTimeInterval(120))
        Thread.sleep(forTimeInterval: 0.6)

        XCTAssertEqual(alertRowCount(p), 1,
                       "同一自然日同一方向只能有一条：去重由 process_alert 的 UNIQUE 索引承担")
        XCTAssertEqual(counter.notifications, 1,
                       "通知本身也必须只发一条：投递前须查 (day, name_key, direction) 是否已有记录")
    }

    /// 反方向独立入账：同一进程的 out 方向不受 in 方向已告警的影响。
    func testUploadDirectionIsIndependentOfDownload() {
        let settings = SettingsStore(defaults: makeDefaults())
        settings.uploadAlertEnabled = true
        settings.alertMinDownloadMB = 1
        settings.alertMinUploadMB = 1
        settings.alertDownloadMultiplier = 1
        settings.alertUploadMultiplier = 1

        let p = SharedTestPersistence.attach("alert-both-directions")
        let monitor = ProcessAlertMonitor(settings: settings, deliver: deliveredOK)

        // 两个方向同时超阈值
        monitor.feed(entities: [entity(90003, "bidirectional", inBps: 2 * MB, outBps: 3 * MB)],
                     interval: 1, now: Date())

        let bothDirectionsLanded = pollUntil(timeout: 4) { alertRowCount(p) == 2 }
        XCTAssertTrue(bothDirectionsLanded)
        let records = awaitValue(2) { p.alertRecords(completion: $0) }
        let directions = Set((records ?? []).map(\.isIn))
        XCTAssertEqual(directions, [true, false], "in 与 out 必须各自入账一条")
    }

    /// 投递被系统拒绝时**不得**写入去重行。
    ///
    /// 回归：原实现先写 `process_alert`（那是「今日已告警」的判据）再投递，
    /// 于是权限被拒时那一行照样落库 → 该进程这天再也不会告警，用户也从没被
    /// 告知。现在改成「投递成功才落库」。
    func testRefusedDeliveryDoesNotWriteDedupRow() {
        let settings = SettingsStore(defaults: makeDefaults())
        settings.uploadAlertEnabled = true
        settings.alertMinDownloadMB = 1
        settings.alertDownloadMultiplier = 1

        let p = SharedTestPersistence.attach("alert-refused")
        let monitor = ProcessAlertMonitor(settings: settings, deliver: deliveredRefused)

        monitor.feed(entities: [entity(90009, "refused-downloader", inBps: 2 * MB, outBps: 0)],
                     interval: 1, now: Date())
        Thread.sleep(forTimeInterval: 0.8)

        XCTAssertEqual(alertRowCount(p), 0,
                       "投递被拒时不得写入 process_alert——否则该进程这一天再也不会告警")
    }

    /// 直接同步数 `process_alert` 的行数。
    /// 用原始 SQL 而非异步的 `alertRecords`：轮询里嵌 XCTestExpectation 会互相干扰，
    /// 而 `HistoryPersistence.db` 是 FULLMUTEX 打开的，主线程只读是安全的。
    private func alertRowCount(_ p: HistoryPersistence) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT COUNT(*) FROM process_alert;"
        guard sqlite3_prepare_v2(p.db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : -1
    }

    // MARK: - L2-14 / L2-15  配额阈值真实记账

    /// 让聚合器读到真实历史表的用量，跨过 80% 后必须在本周期记下 fired key。
    private func makeQuotaScenario(suiteTag: String,
                                   seedFiredKeys: [String]? = nil,
                                   delivered: Bool = true)
    -> (UsageAggregator, QuotaMonitor, UserDefaults, HistoryPersistence) {
        let defaults = makeDefaults()
        if let seed = seedFiredKeys {
            defaults.set(seed, forKey: "quotaFiredKeys")
        }
        let settings = SettingsStore(defaults: defaults)
        settings.quotaEnabled = true
        settings.quotaPeriod = "day"
        settings.quotaLimitGB = 1                      // 1 GiB 上限

        let p = SharedTestPersistence.attach(suiteTag)

        // 写入约 1000 MiB（97.7% of 1 GiB）：越过 80%，但未到 100%
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for i in 0..<10 {
            p.append(HistoryRow(ts: nowMs - Int64(i) * 1000,
                                inBytesPerSec: 100 * MB, outBytesPerSec: 0))
        }
        Thread.sleep(forTimeInterval: 0.4)

        let agg = UsageAggregator(minFetchInterval: 0)
        let deliver: NotificationDelivery = delivered ? deliveredOK : deliveredRefused
        let monitor = QuotaMonitor(settings: settings, aggregator: agg,
                                  defaults: defaults, deliver: deliver)

        // 关键时序：QuotaMonitor 的 sink 忽略事件携带的值，而是调用 check() 去**实时读**
        // 聚合器。首次 check 只负责把 prevPercent 武装到当前值。如果这一拍晚于
        // `agg.tick()`，首次武装就会直接把基准定在 97%，之后永远不触发跨越。
        // 因此这里先泵一拍 runloop，保证「武装时聚合器仍为 0」。
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        return (agg, monitor, defaults, p)
    }

    func testQuotaFiresAndRecordsFiredKey() {
        // 必须持有 monitor 的强引用：绑到 `_` 会被 ARC 立刻释放，
        // 其 cancellables 一并释放 → 后续再没有任何 check() 被调用。
        let (agg, monitor, defaults, _) = makeQuotaScenario(suiteTag: "quota-fire")
        XCTAssertTrue(monitor.config().enabled, "配额开关必须为开，否则 check() 会提前返回")

        // 首次 tick 只负责「武装」prevPercent
        agg.tick()
        let loaded = pollUntil(timeout: 3) { agg.today.total > 0 }
        XCTAssertTrue(loaded, "聚合器应能从 history 表读到今日用量")

        let fired = pollUntil(timeout: 3) {
            !(defaults.stringArray(forKey: "quotaFiredKeys") ?? []).isEmpty
        }
        XCTAssertTrue(fired, "跨过 80% 后必须记下 fired key")

        let keys = defaults.stringArray(forKey: "quotaFiredKeys") ?? []
        XCTAssertTrue(keys.contains { $0.hasSuffix(":80") }, "应记录 80% 档：\(keys)")
        XCTAssertFalse(keys.contains { $0.hasSuffix(":100") },
                       "97.7% 未越过 100%，不得记录 100% 档：\(keys)")
    }

    func testQuotaReArmsAfterPeriodRollover() {
        // 预置一个「上一周期」的 key，模拟周期已滚动
        let stale = "2000-01-01T00:00:00Z:80"
        // 同上：monitor 必须被强引用持有，否则订阅在作用域结束即失效。
        let (agg, monitor, defaults, _) = makeQuotaScenario(suiteTag: "quota-rearm",
                                                           seedFiredKeys: [stale])
        XCTAssertTrue(monitor.config().enabled)

        agg.tick()
        let loadedAgain = pollUntil(timeout: 3) { agg.today.total > 0 }
        XCTAssertTrue(loadedAgain)

        let reArmed = pollUntil(timeout: 3) {
            let keys = defaults.stringArray(forKey: "quotaFiredKeys") ?? []
            return keys.count > 1 && keys.contains { $0 != stale && $0.hasSuffix(":80") }
        }
        XCTAssertTrue(reArmed,
                      "周期滚动后同一阈值必须重新武装（新周期的 key 与旧 key 不同）")
    }

    /// 投递被系统拒绝时**不得**记录 fired key。
    ///
    /// 回归：原实现无论投递成败都写 fired key，于是权限被拒时该阈值本周期
    /// 被永久标记为「已通知」，之后再也不会重试。现在只有投递成功才记账。
    func testRefusedDeliveryDoesNotMarkThresholdFired() {
        let (agg, monitor, defaults, _) = makeQuotaScenario(suiteTag: "quota-refused",
                                                           delivered: false)
        XCTAssertTrue(monitor.config().enabled)

        agg.tick()
        let loaded = pollUntil(timeout: 3) { agg.today.total > 0 }
        XCTAssertTrue(loaded, "聚合器应能读到今日用量")

        // 给 check() 足够机会跑（它会尝试投递并被拒）
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        let keys = defaults.stringArray(forKey: "quotaFiredKeys") ?? []
        XCTAssertTrue(keys.isEmpty,
                      "投递被拒时不得记录 fired key——否则该阈值本周期不会再提醒：\(keys)")
    }
}
