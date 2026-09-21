//
//  QuotaMonitorTests.swift
//  FlowTraceTests
//
//  Covers the quota decision layer: threshold-set construction, the crossing
//  rule, per-period dedup, and the fired-key persistence.
//
//  Everything runs against the real types — `QuotaMonitor` and `SettingsStore`
//  both take their dependencies by injection — and each test gets its own
//  `UserDefaults` suite, because a test run must never write to the user's real
//  preferences (`QuotaMonitor` persists its fired keys, `SettingsStore` writes
//  every property through a `@Published` sink).
//
//  Replaces `scripts/verify_quota.swift`, which re-implemented the rule by hand
//  and had to be kept in sync manually.
//

import XCTest
@testable import FlowTrace

final class QuotaMonitorTests: XCTestCase {

    /// Mirrors `QuotaMonitor.firedKeysDefaultsKey`, which is private.
    private let firedKeysKey = "quotaFiredKeys"

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "FlowTraceTests.quota.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        // Drop the throwaway domain so repeated runs cannot see each other.
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        settings = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeMonitor() -> QuotaMonitor {
        QuotaMonitor(settings: settings, aggregator: UsageAggregator(), defaults: defaults)
    }

    // MARK: - Threshold set

    private func thresholds(custom: Int) -> [Int] {
        settings.quotaCustomPercent = custom
        return makeMonitor().config().thresholds
    }

    func testThresholdsDefaultTo80And100() {
        XCTAssertEqual(thresholds(custom: 0), [80, 100])
    }

    func testCustomThresholdIsMergedInAscendingOrder() {
        XCTAssertEqual(thresholds(custom: 90), [80, 90, 100])
    }

    func testCustomThresholdDuplicatingABuiltInIsDeduped() {
        XCTAssertEqual(thresholds(custom: 80), [80, 100])
        XCTAssertEqual(thresholds(custom: 100), [80, 100])
    }

    func testOutOfRangeCustomThresholdsAreIgnored() {
        XCTAssertEqual(thresholds(custom: -5), [80, 100])
        XCTAssertEqual(thresholds(custom: 150), [80, 100])
    }

    // MARK: - Limit

    func testLimitBytesComesFromGB() {
        settings.quotaLimitGB = 2
        XCTAssertEqual(makeMonitor().config().limitBytes, 2 * 1024 * 1024 * 1024)
    }

    func testLimitBytesClampsToAtLeastOneGB() {
        settings.quotaLimitGB = 0
        XCTAssertEqual(makeMonitor().config().limitBytes, 1024 * 1024 * 1024)
    }

    // MARK: - Crossing rule

    private let periodKey = "2026-09-01T00:00:00Z"

    func testFiresWhenThePercentCrossesTheThreshold() {
        XCTAssertTrue(QuotaMonitor.shouldFire(prev: 10, current: 85, threshold: 80,
                                              key: periodKey, alreadyFired: []))
    }

    func testDoesNotFireWhileBelowTheThreshold() {
        XCTAssertFalse(QuotaMonitor.shouldFire(prev: 10, current: 79, threshold: 80,
                                               key: periodKey, alreadyFired: []))
    }

    func testDoesNotRefireWhenAlreadyAboveTheThreshold() {
        // `prev >= t` means the crossing happened earlier (or before launch).
        // Without that guard one crossing would become a notification per frame.
        XCTAssertFalse(QuotaMonitor.shouldFire(prev: 85, current: 90, threshold: 80,
                                               key: periodKey, alreadyFired: []))
    }

    func testDoesNotFireTheSameThresholdTwiceInOnePeriod() {
        XCTAssertFalse(QuotaMonitor.shouldFire(prev: 10, current: 85, threshold: 80,
                                               key: periodKey, alreadyFired: [periodKey]))
    }

    func testASingleCheckCanCrossSeveralThresholds() {
        // 70 → 105 skips past both 80 and 100 in one observation.
        let fired = [80, 100].filter {
            QuotaMonitor.shouldFire(prev: 70, current: 105, threshold: $0,
                                    key: periodKey, alreadyFired: [])
        }
        XCTAssertEqual(fired, [80, 100])
    }

    func testANewPeriodKeyReArmsTheThreshold() {
        let nextPeriod = "2026-10-01T00:00:00Z"
        // Already fired this period ...
        XCTAssertFalse(QuotaMonitor.shouldFire(prev: 10, current: 85, threshold: 80,
                                               key: periodKey, alreadyFired: [periodKey]))
        // ... but the same numbers fire again once the period rolls over.
        XCTAssertTrue(QuotaMonitor.shouldFire(prev: 10, current: 85, threshold: 80,
                                              key: nextPeriod, alreadyFired: [periodKey]))
    }

    // MARK: - Period start keys

    func testMonthPeriodKeyIsTheFirstOfTheMonth() {
        let now = Date()
        let calendar = Calendar.current
        let expected = ISO8601DateFormatter().string(
            from: calendar.date(from: calendar.dateComponents([.year, .month], from: now))
                ?? calendar.startOfDay(for: now)
        )
        XCTAssertEqual(QuotaMonitor.periodStartKey(period: "month", now: now), expected)
    }

    func testDayPeriodKeyIsLocalMidnight() {
        let now = Date()
        let expected = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: now))
        XCTAssertEqual(QuotaMonitor.periodStartKey(period: "day", now: now), expected)
    }

    func testPeriodStartKeysAreOrderedMonthThenWeekThenDay() {
        // A fixed mid-month instant, so the assertion does not depend on the
        // day the suite happens to run. ISO-8601 strings in a single format
        // sort chronologically.
        let midMonth = Calendar.current.date(
            from: DateComponents(year: 2026, month: 9, day: 15, hour: 12)
        )!
        let month = QuotaMonitor.periodStartKey(period: "month", now: midMonth)
        let week = QuotaMonitor.periodStartKey(period: "week", now: midMonth)
        let day = QuotaMonitor.periodStartKey(period: "day", now: midMonth)

        XCTAssertLessThan(month, day, "month starts before the 15th")
        XCTAssertLessThanOrEqual(week, day, "the week cannot start after today")
        XCTAssertGreaterThanOrEqual(week, month, "the week cannot start before the month")
    }

    // MARK: - Fired-key persistence

    func testFiredKeysAreLoadedFromDefaults() {
        defaults.set([periodKey], forKey: firedKeysKey)
        XCTAssertEqual(makeMonitor().firedKeys, [periodKey])
    }

    func testResetFiredKeysClearsMemoryAndDefaults() {
        defaults.set([periodKey], forKey: firedKeysKey)
        let monitor = makeMonitor()
        XCTAssertEqual(monitor.firedKeys, [periodKey])

        monitor.resetFiredKeys()

        XCTAssertTrue(monitor.firedKeys.isEmpty)
        XCTAssertNil(defaults.stringArray(forKey: firedKeysKey))
    }
}
