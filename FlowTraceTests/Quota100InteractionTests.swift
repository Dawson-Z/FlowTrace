//
//  Quota100InteractionTests.swift
//  FlowTraceTests
//
//  Spec: .trellis/tasks/09-28-notification-interactions — quota 100% growth
//  re-fire + mute actions.
//
//  Two layers:
//    - pure: `shouldRefire100` / `refireIncrementBytes` (no aggregation)
//    - integration: the full QuotaMonitor pipeline against a real history
//      table + a recording deliver stub (no real UNUserNotificationCenter)
//

import XCTest
import UserNotifications
@testable import FlowTrace

final class Quota100PureTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let todayKey = "2026-10-02T00:00:00Z"

    func testBelow100PercentNeverRefires() {
        XCTAssertFalse(QuotaMonitor.shouldRefire100(
            currentPercent: 99.9, now: now, mutedUntil: nil, mutedDay: nil,
            todayKey: todayKey, lastNotifiedBytes: 100, usedBytes: 5_000_000,
            incrementBytes: 1_000_000))
    }

    func testNilBaselineWaitsForCrossingPath() {
        // nil = "no 100% notification in this period yet" — the crossing path
        // owns the first fire, so the growth branch must stand down.
        XCTAssertFalse(QuotaMonitor.shouldRefire100(
            currentPercent: 150, now: now, mutedUntil: nil, mutedDay: nil,
            todayKey: todayKey, lastNotifiedBytes: nil, usedBytes: 5_000_000,
            incrementBytes: 1_000_000))
    }

    func testGrowthBelowIncrementDoesNotRefire() {
        XCTAssertFalse(QuotaMonitor.shouldRefire100(
            currentPercent: 105, now: now, mutedUntil: nil, mutedDay: nil,
            todayKey: todayKey, lastNotifiedBytes: 5_000_000, usedBytes: 5_500_000,
            incrementBytes: 1_000_000))
    }

    func testGrowthAtIncrementRefires() {
        // >= semantics: exactly the increment counts as "kept growing".
        XCTAssertTrue(QuotaMonitor.shouldRefire100(
            currentPercent: 105, now: now, mutedUntil: nil, mutedDay: nil,
            todayKey: todayKey, lastNotifiedBytes: 5_000_000, usedBytes: 6_000_000,
            incrementBytes: 1_000_000))
    }

    func testMutedUntilBlocksOnlyWhileActive() {
        let future = now.addingTimeInterval(600)
        let past = now.addingTimeInterval(-600)
        XCTAssertFalse(QuotaMonitor.shouldRefire100(
            currentPercent: 150, now: now, mutedUntil: future, mutedDay: nil,
            todayKey: todayKey, lastNotifiedBytes: 100, usedBytes: 5_000_000,
            incrementBytes: 1_000_000), "静音期内不得重发")
        XCTAssertTrue(QuotaMonitor.shouldRefire100(
            currentPercent: 150, now: now, mutedUntil: past, mutedDay: nil,
            todayKey: todayKey, lastNotifiedBytes: 100, usedBytes: 5_000_000,
            incrementBytes: 1_000_000), "静音过期后恢复增长判定")
    }

    func testMutedDayBlocksOnlyThatDay() {
        XCTAssertFalse(QuotaMonitor.shouldRefire100(
            currentPercent: 150, now: now, mutedUntil: nil, mutedDay: todayKey,
            todayKey: todayKey, lastNotifiedBytes: 100, usedBytes: 5_000_000,
            incrementBytes: 1_000_000), "今日静音期内不得重发")
        XCTAssertTrue(QuotaMonitor.shouldRefire100(
            currentPercent: 150, now: now, mutedUntil: nil, mutedDay: "2000-01-01T00:00:00Z",
            todayKey: todayKey, lastNotifiedBytes: 100, usedBytes: 5_000_000,
            incrementBytes: 1_000_000), "静音日不是今天则不拦截")
    }

    func testRefireIncrementIsOnePercentOfLimitWithFloor() {
        XCTAssertEqual(QuotaMonitor.refireIncrementBytes(limit: 1_073_741_824),
                       10_737_418, "1 GiB 配额的重触发增量 = 1%")
        XCTAssertEqual(QuotaMonitor.refireIncrementBytes(limit: 50),
                       1, "极小配额落到 1 字节下限")
    }
}

/// Full-pipeline tests: real history table + real aggregator + recording
/// deliver stub. The 100% crossing fires together with 80% on the first
/// growth observation, so the counters here always match on identifiers
/// ending in "-100" rather than raw counts.
final class Quota100InteractionTests: TempDefaultsTestCase {

    private let MB = 1024 * 1024

    /// Records delivered requests (the deliver closure runs synchronously on
    /// the main thread here, but stay defensive).
    private final class Recorder {
        private let lock = NSLock()
        private var requests: [UNNotificationRequest] = []
        func record(_ r: UNNotificationRequest) {
            lock.lock(); requests.append(r); lock.unlock()
        }
        func count100() -> Int {
            lock.lock(); defer { lock.unlock() }
            return requests.filter { $0.identifier.hasSuffix("-100") }.count
        }
        func first100() -> UNNotificationRequest? {
            lock.lock(); defer { lock.unlock() }
            return requests.first { $0.identifier.hasSuffix("-100") }
        }
    }

    /// Monitors must be retained for their Combine subscriptions to live
    /// (same ARC lesson as AlertAndQuotaIntegrationTests).
    private var retain: [QuotaMonitor] = []

    /// 1.05 GiB spread over 11 rows: crosses 80% AND 100% on the first
    /// growth observation.
    private func makeScenario(tag: String)
    -> (UsageAggregator, QuotaMonitor, Recorder, HistoryPersistence) {
        let defaults = makeDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.quotaEnabled = true
        settings.quotaPeriod = "day"
        settings.quotaLimitGB = 1

        let p = SharedTestPersistence.attach(tag)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for i in 0..<11 {
            p.append(HistoryRow(ts: nowMs - Int64(i) * 1000,
                                inBytesPerSec: 100 * MB, outBytesPerSec: 0))
        }
        Thread.sleep(forTimeInterval: 0.4)

        let recorder = Recorder()
        let deliver: NotificationDelivery = { request, completion in
            recorder.record(request)
            completion(true)
        }
        let agg = UsageAggregator(minFetchInterval: 0)
        let monitor = QuotaMonitor(settings: settings, aggregator: agg,
                                   defaults: defaults, deliver: deliver)
        retain.append(monitor)
        // Arm prevPercent at 0 before the first tick (same timing rule as
        // AlertAndQuotaIntegrationTests: otherwise the arming observation
        // lands after the data is visible and the crossing never "crosses").
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        return (agg, monitor, recorder, p)
    }

    private func appendGrowth(_ p: HistoryPersistence, mib: Int) {
        p.append(HistoryRow(ts: Int64(Date().timeIntervalSince1970 * 1000),
                            inBytesPerSec: mib * MB, outBytesPerSec: 0))
    }

    /// Pump the runloop long enough for tick → sink → check → deliver.
    private func pump(_ seconds: TimeInterval = 0.6) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func test100CrossesOnceThenRefiresOnlyOnGrowth() {
        let (agg, monitor, recorder, p) = makeScenario(tag: "q100-cross")

        agg.tick()
        pump()
        let crossed = pollUntil(timeout: 3) { recorder.count100() >= 1 }
        XCTAssertTrue(crossed, "首拍跨过 100% 必须触发一次")
        XCTAssertEqual(recorder.count100(), 1, "首拍只触发一次")

        // No growth: repeated ticks must not re-fire (spec §2.2 — dismiss /
        // acknowledge leave state unchanged, only growth re-fires).
        agg.tick()
        pump()
        XCTAssertEqual(recorder.count100(), 1, "无增长时不得重发")

        // Growth below the increment (1 MiB < 1% of 1 GiB): still no re-fire.
        appendGrowth(p, mib: 1)
        agg.tick()
        pump()
        XCTAssertEqual(recorder.count100(), 1, "增长不足增量门槛时不得重发")

        // Growth ≥ increment: exactly one re-fire.
        appendGrowth(p, mib: 20)
        agg.tick()
        pump()
        let refired = pollUntil(timeout: 3) { recorder.count100() >= 2 }
        XCTAssertTrue(refired, "增长超过增量门槛后必须重发")
        XCTAssertEqual(recorder.count100(), 2, "一次跨越增量的增长只重发一次")
    }

    func testFirst100NotificationCarriesCategoryAndRoute() {
        let (agg, monitor, recorder, _) = makeScenario(tag: "q100-meta")

        agg.tick()
        pump()
        _ = pollUntil(timeout: 3) { recorder.count100() >= 1 }

        let request = recorder.first100()
        XCTAssertNotNil(request, "100% 通知必须已投递")
        XCTAssertEqual(request?.content.categoryIdentifier,
                       LocalNotification.quota100CategoryID)
        XCTAssertEqual(request?.content.userInfo[LocalNotification.routeKey] as? String,
                       LocalNotification.Route.settingsQuota)
    }

    func testMuteTodayBlocksRefireAndSurvivesInModel() {
        let (agg, monitor, recorder, p) = makeScenario(tag: "q100-mutetoday")

        agg.tick()
        pump()
        _ = pollUntil(timeout: 3) { recorder.count100() >= 1 }

        monitor.mute100ForToday()
        XCTAssertEqual(monitor.mutedDay100,
                       QuotaMonitor.periodStartKey(period: "day", now: Date()),
                       "今日静音必须记录为今天的日 key")

        // handleQuota100Action routes the same identifier to the same state
        // (idempotent: the day key does not change).
        monitor.handleQuota100Action(LocalNotification.Quota100Action.muteToday)
        XCTAssertEqual(monitor.mutedDay100,
                       QuotaMonitor.periodStartKey(period: "day", now: Date()))

        appendGrowth(p, mib: 30)
        agg.tick()
        pump()
        XCTAssertEqual(recorder.count100(), 1,
                       "「今天不再提醒」后即使流量持续增长也不得重发（直到次日）")
    }

    func testMuteForOneHourBlocksRefire() {
        let (agg, monitor, recorder, p) = makeScenario(tag: "q100-mute1h")

        agg.tick()
        pump()
        _ = pollUntil(timeout: 3) { recorder.count100() >= 1 }

        monitor.mute100ForOneHour()
        XCTAssertNotNil(monitor.mutedUntil100)
        // handleQuota100Action routes to the same handler.
        monitor.handleQuota100Action(LocalNotification.Quota100Action.mute1Hour)
        XCTAssertNotNil(monitor.mutedUntil100)

        appendGrowth(p, mib: 30)
        agg.tick()
        pump()
        XCTAssertEqual(recorder.count100(), 1, "1 小时静音期内不得重发")
    }

    func testAcknowledgeRebasesGrowthBaseline() {
        let (agg, monitor, recorder, p) = makeScenario(tag: "q100-ack")

        agg.tick()
        pump()
        _ = pollUntil(timeout: 3) { recorder.count100() >= 1 }

        // Small growth (below increment), then acknowledge: the baseline
        // moves to current usage, so the sub-increment growth is absorbed.
        appendGrowth(p, mib: 2)
        agg.tick()
        pump()
        monitor.handleQuota100Action(LocalNotification.Quota100Action.acknowledge)

        appendGrowth(p, mib: 2)   // cumulative growth since ack still < 1%
        agg.tick()
        pump()
        XCTAssertEqual(recorder.count100(), 1, "已知确认后，小额增长被新基线吸收")

        // A fresh big growth re-fires again.
        appendGrowth(p, mib: 30)
        agg.tick()
        pump()
        let refired = pollUntil(timeout: 3) { recorder.count100() >= 2 }
        XCTAssertTrue(refired, "确认后的大幅增长必须重发")
    }

    func testClearDataResets100State() {
        let (agg, monitor, recorder, _) = makeScenario(tag: "q100-reset")

        agg.tick()
        pump()
        _ = pollUntil(timeout: 3) { recorder.count100() >= 1 }

        monitor.mute100ForToday()
        monitor.mute100ForOneHour()
        monitor.resetFiredKeys()

        XCTAssertNil(monitor.mutedDay100)
        XCTAssertNil(monitor.mutedUntil100)
        XCTAssertNil(monitor.notifiedAtBytes100)
        _ = recorder
    }
}
